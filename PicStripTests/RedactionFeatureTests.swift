import UIKit
import XCTest
@testable import PicStrip

/// Test methods that construct or call `ScrubberViewModel` (or any other
/// `@MainActor`-isolated type) **must be `async`**. Under Xcode 26 / Swift 6
/// strict concurrency, XCTest only hops sync test methods onto MainActor when
/// the class isolation is propagated through `await` — synchronous test
/// methods on a `@MainActor` class get invoked off-main, and the first
/// `ScrubberViewModel()` call then crashes with an actor isolation violation.
/// Tests that only manipulate value types or static methods (e.g. the
/// `imageNormalizedPoint` helpers, `RedactionRegion` math) are safe to keep
/// synchronous.
@MainActor
final class RedactionFeatureTests: XCTestCase {

    func testDetectedPIIConvertsIntoEditableRedactionRegions() async {
        let viewModel = ScrubberViewModel()
        let email = DetectionResult(
            type: .email,
            score: 0.94,
            instances: [
                DetectedInstance(
                    snippet: "test@example.com",
                    boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1),
                    score: 0.94
                )
            ]
        )

        viewModel.detectedPII = [email]
        viewModel.typesToRedact = [.email]
        viewModel.resetDetectedRedactionRegions()

        XCTAssertEqual(viewModel.redactionRegions.count, 1)
        XCTAssertEqual(viewModel.redactionRegions.first?.source, .detected)
        XCTAssertEqual(viewModel.redactionRegions.first?.type, .email)
        XCTAssertEqual(viewModel.enabledRedactionRegions.count, 1)

        viewModel.typesToRedact = []
        XCTAssertTrue(viewModel.enabledRedactionRegions.isEmpty)
    }

    func testRedactionRegionMoveAndResizeClampToImageBounds() {
        let original = CGRect(x: 0.9, y: 0.9, width: 0.3, height: 0.3)
        let clamped = RedactionRegion.clamped(original)

        XCTAssertEqual(clamped.maxX, 1, accuracy: 0.0001)
        XCTAssertEqual(clamped.maxY, 1, accuracy: 0.0001)

        let moved = RedactionRegion.moved(
            CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
            by: CGSize(width: -0.5, height: 1.0)
        )
        XCTAssertEqual(moved.minX, 0, accuracy: 0.0001)
        XCTAssertEqual(moved.maxY, 1, accuracy: 0.0001)

        let resized = RedactionRegion.resized(
            CGRect(x: 0.9, y: 0.9, width: 0.05, height: 0.05),
            by: CGSize(width: 0.5, height: 0.5)
        )
        XCTAssertLessThanOrEqual(resized.maxX, 1)
        XCTAssertLessThanOrEqual(resized.maxY, 1)
    }

    func testImageRedactorBurnsCustomRegionRect() async throws {
        let image = try makeImage(color: .white, size: CGSize(width: 20, height: 20))
        let rendered = await ImageRedactor().redact(
            image: image,
            specs: [RedactionSpec(rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), style: .solid, color: .black, isEnabled: true)]
        )
        let redacted = try XCTUnwrap(rendered)

        XCTAssertEqual(try pixelColor(in: redacted, x: 2, y: 2), [0, 0, 0, 255])
    }

    func testReviewPreviewPrefersRedactedImageForCustomRedactions() async throws {
        let viewModel = ScrubberViewModel()
        let source = try makeImage(color: .green)
        let processed = try makeImage(color: .blue)
        let redacted = try makeImage(color: .red)

        viewModel.sourceUIImage = source
        viewModel.processedData = try XCTUnwrap(processed.pngData())
        viewModel.addCustomRedaction(rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        viewModel.redactedUIImage = redacted

        XCTAssertEqual(
            try pixelColor(in: XCTUnwrap(viewModel.reviewPreviewUIImage), x: 0, y: 0),
            try pixelColor(in: redacted, x: 0, y: 0)
        )
    }

    // MARK: - Undo / Redo tests

    /// After adding a region canUndo becomes true and canRedo stays false.
    func testCanUndoAfterAdd() async {
        let vm = ScrubberViewModel()
        XCTAssertFalse(vm.canUndo)
        XCTAssertFalse(vm.canRedo)
        vm.addCustomRedaction(rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        XCTAssertTrue(vm.canUndo, "canUndo must be true after addCustomRedaction")
        XCTAssertFalse(vm.canRedo, "canRedo must remain false after a fresh add")
    }

    /// Undoing an add removes the region and restores the previous count.
    func testUndoRestoresRegionCountAfterAdd() async {
        let vm = ScrubberViewModel()
        let before = vm.redactionRegions.count
        vm.addCustomRedaction(rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        XCTAssertEqual(vm.redactionRegions.count, before + 1)
        vm.undoRedaction()
        XCTAssertEqual(vm.redactionRegions.count, before,
                       "Undo must restore the region array to its pre-add state")
        XCTAssertFalse(vm.canUndo)
        XCTAssertTrue(vm.canRedo, "canRedo must be true after undoing an add")
    }

    /// Redo re-applies the undone add.
    func testRedoReappliesAdd() async {
        let vm = ScrubberViewModel()
        let before = vm.redactionRegions.count
        vm.addCustomRedaction(rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        vm.undoRedaction()
        vm.redoRedaction()
        XCTAssertEqual(vm.redactionRegions.count, before + 1,
                       "Redo must re-apply the undone add")
        XCTAssertFalse(vm.canRedo, "canRedo must be false after redoing the last action")
        XCTAssertTrue(vm.canUndo)
    }

    /// Performing a new action after undo clears the redo stack.
    func testNewActionClearsRedoStack() async {
        let vm = ScrubberViewModel()
        vm.addCustomRedaction(rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        vm.undoRedaction()
        XCTAssertTrue(vm.canRedo)
        // A brand-new add should clear the redo stack.
        vm.addCustomRedaction(rect: CGRect(x: 0.3, y: 0.3, width: 0.1, height: 0.1))
        XCTAssertFalse(vm.canRedo, "Redo stack must be cleared when the user performs a new action")
    }

    /// Undoing a delete restores the deleted region.
    func testUndoRestoresRegionAfterDelete() async {
        let vm = ScrubberViewModel()
        vm.addCustomRedaction(rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        // Clear the undo history from the add so we test delete in isolation.
        // (We do this by undoing the add and redoing it, leaving canUndo false.)
        // Simpler: just note the count after the add.
        let countAfterAdd = vm.redactionRegions.count
        vm.selectRedactionRegion(id: vm.redactionRegions.last?.id)
        vm.deleteSelectedRedactionRegion()
        XCTAssertEqual(vm.redactionRegions.count, countAfterAdd - 1)
        vm.undoRedaction()
        XCTAssertEqual(vm.redactionRegions.count, countAfterAdd,
                       "Undo must restore the deleted region")
    }

    /// Undoing a move restores the region's rect to its pre-drag position.
    func testUndoRestoresRectAfterMove() async {
        let vm = ScrubberViewModel()
        let originalRect = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        vm.addCustomRedaction(rect: originalRect)
        let regionID = vm.redactionRegions.last!.id
        // Simulate what the gesture layer does: beginRedactionUpdate, then updateRedactionRegion.
        vm.beginRedactionUpdate(id: regionID)
        let movedRect = CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2)
        vm.updateRedactionRegion(id: regionID, rect: movedRect)
        XCTAssertEqual(vm.redactionRegions.last?.rect.minX ?? 0, movedRect.minX, accuracy: 0.001)
        vm.undoRedaction()
        // After undo the rect should be back near originalRect (clamped).
        let restoredRect = vm.redactionRegions.first { $0.id == regionID }?.rect
        XCTAssertNotNil(restoredRect)
        XCTAssertEqual(restoredRect!.minX, RedactionRegion.clamped(originalRect).minX, accuracy: 0.001,
                       "Undo must restore the region to its pre-drag rect")
    }

    /// `beginRedactionUpdate` called repeatedly for the same ID within a gesture
    /// must push only one undo snapshot, not one per drag event.
    func testBeginRedactionUpdateDeduplicated() async {
        let vm = ScrubberViewModel()
        let rect = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        vm.addCustomRedaction(rect: rect)
        _ = vm.redactionRegions.last!.id  // captured only to confirm the add succeeded
        // Clear the add's snapshot so we can count from zero.
        vm.undoRedaction()   // undoes the add — stack now empty
        vm.redoRedaction()   // redoes — stack: [pre-add], redo: []
        // Now undo the add again so we start with no regions and empty stacks.
        vm.undoRedaction()
        vm.addCustomRedaction(rect: rect) // 1 snapshot pushed (the add)
        let regionID2 = vm.redactionRegions.last!.id
        // Simulate 3 drag events for the same gesture — should produce only 1 snapshot.
        vm.beginRedactionUpdate(id: regionID2)
        vm.updateRedactionRegion(id: regionID2, rect: CGRect(x: 0.2, y: 0.1, width: 0.2, height: 0.2))
        vm.beginRedactionUpdate(id: regionID2) // same ID, must be a no-op
        vm.updateRedactionRegion(id: regionID2, rect: CGRect(x: 0.3, y: 0.1, width: 0.2, height: 0.2))
        vm.beginRedactionUpdate(id: regionID2) // same ID, must be a no-op
        vm.updateRedactionRegion(id: regionID2, rect: CGRect(x: 0.4, y: 0.1, width: 0.2, height: 0.2))
        // The stack now holds: [snapshot-before-add, snapshot-before-drag]
        // One undo steps back to the post-add position (before drag started).
        vm.undoRedaction()
        let rectAfterUndoDrag = vm.redactionRegions.first { $0.id == regionID2 }?.rect
        XCTAssertNotNil(rectAfterUndoDrag, "Region must still exist after undoing the drag")
        XCTAssertEqual(rectAfterUndoDrag!.minX, RedactionRegion.clamped(rect).minX, accuracy: 0.001,
                       "One undo must step all the way back to the pre-drag rect")
        XCTAssertTrue(vm.canUndo,
                      "A second undo step must still be available (the add snapshot)")
    }

    /// Undo stack is capped at 50; pushing 60 actions must not exceed the cap.
    func testUndoStackCapAt50() async {
        let vm = ScrubberViewModel()
        for i in 0..<60 {
            let x = CGFloat(i) * 0.01
            vm.addCustomRedaction(rect: CGRect(x: x, y: 0.01, width: 0.05, height: 0.05))
        }
        // We can only undo 50 times, not 60.
        var undoCount = 0
        while vm.canUndo {
            vm.undoRedaction()
            undoCount += 1
            XCTAssertLessThanOrEqual(undoCount, 50, "Undo stack must never exceed 50 entries")
        }
        XCTAssertEqual(undoCount, 50, "Exactly 50 undo steps should be available after 60 actions")
    }

    // MARK: - toggleRedactionRegion(id:) tests

    /// Toggling a custom region flips its isEnabled flag.
    func testToggleCustomRegionEnablement() async {
        let vm = ScrubberViewModel()
        vm.addCustomRedaction(rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        let id = vm.redactionRegions.last!.id
        XCTAssertTrue(vm.redactionRegions.last!.isEnabled, "Custom regions start enabled")

        vm.toggleRedactionRegion(id: id)
        XCTAssertFalse(vm.redactionRegions.first { $0.id == id }!.isEnabled,
                       "First toggle must disable the custom region")

        vm.toggleRedactionRegion(id: id)
        XCTAssertTrue(vm.redactionRegions.first { $0.id == id }!.isEnabled,
                      "Second toggle must re-enable the custom region")
    }

    /// Toggling one detected instance disables only that region; other instances
    /// of the same type remain enabled (per-instance granularity).
    func testToggleDetectedRegionAffectsOnlyThatInstance() async {
        let vm = ScrubberViewModel()
        let email = DetectionResult(
            type: .email,
            score: 0.95,
            instances: [
                DetectedInstance(snippet: "a@b.com",
                                 boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1),
                                 score: 0.95),
                DetectedInstance(snippet: "c@d.com",
                                 boundingBox: CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.1),
                                 score: 0.88)
            ]
        )
        vm.detectedPII = [email]
        vm.typesToRedact = [.email]
        vm.resetDetectedRedactionRegions()

        XCTAssertEqual(vm.redactionRegions.count, 2)
        XCTAssertTrue(vm.redactionRegions.allSatisfy(\.isEnabled), "All detected regions start enabled")

        // Toggle first instance only — second must stay enabled
        let firstID = vm.redactionRegions.first!.id
        let secondID = vm.redactionRegions.last!.id
        vm.toggleRedactionRegion(id: firstID)

        XCTAssertFalse(vm.redactionRegions.first { $0.id == firstID }!.isEnabled,
                       "Toggled instance must be disabled")
        XCTAssertTrue(vm.redactionRegions.first { $0.id == secondID }!.isEnabled,
                      "Other instance of the same type must remain enabled")
        XCTAssertTrue(vm.typesToRedact.contains(.email),
                      "typesToRedact must not change — it is only the initial-seeding mechanism")

        // enabledRedactionRegions must reflect the per-instance state
        XCTAssertEqual(vm.enabledRedactionRegions.count, 1)

        // Toggle again — first re-enabled; both enabled
        vm.toggleRedactionRegion(id: firstID)
        XCTAssertTrue(vm.redactionRegions.allSatisfy(\.isEnabled))
    }

    /// Toggling a region is undoable — one undo step restores the previous state.
    func testToggleRegionIsUndoable() async {
        let vm = ScrubberViewModel()
        vm.addCustomRedaction(rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        let id = vm.redactionRegions.last!.id

        vm.toggleRedactionRegion(id: id)
        XCTAssertFalse(vm.redactionRegions.first { $0.id == id }!.isEnabled)
        XCTAssertTrue(vm.canUndo, "toggle must push an undo snapshot")

        vm.undoRedaction()
        XCTAssertTrue(vm.redactionRegions.first { $0.id == id }!.isEnabled,
                      "Undo must restore the region to its enabled state")
    }

    // MARK: - deleteRedactionRegion(id:) tests

    /// Deleting by ID removes the correct region without requiring prior selection.
    func testDeleteRedactionRegionById() async {
        let vm = ScrubberViewModel()
        vm.addCustomRedaction(rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        vm.addCustomRedaction(rect: CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2))
        XCTAssertEqual(vm.redactionRegions.count, 2)

        let targetID = vm.redactionRegions.first!.id
        vm.deleteRedactionRegion(id: targetID)

        XCTAssertEqual(vm.redactionRegions.count, 1,
                       "deleteRedactionRegion(id:) must remove exactly the targeted region")
        XCTAssertFalse(vm.redactionRegions.contains { $0.id == targetID },
                       "The deleted region must no longer exist in the array")
    }

    /// Deleting by ID is undoable — the region is restored after one undo step.
    func testDeleteRedactionRegionByIdIsUndoable() async {
        let vm = ScrubberViewModel()
        vm.addCustomRedaction(rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        let targetID = vm.redactionRegions.last!.id
        let countBefore = vm.redactionRegions.count

        vm.deleteRedactionRegion(id: targetID)
        XCTAssertEqual(vm.redactionRegions.count, countBefore - 1)
        XCTAssertTrue(vm.canUndo, "Delete must push an undo snapshot")

        vm.undoRedaction()
        XCTAssertEqual(vm.redactionRegions.count, countBefore,
                       "Undo must restore the region removed by deleteRedactionRegion(id:)")
        XCTAssertTrue(vm.redactionRegions.contains { $0.id == targetID },
                      "The restored region must have the same ID")
    }

    /// Deleting the currently selected region clears the selection.
    func testDeleteSelectedRegionByIdClearsSelection() async {
        let vm = ScrubberViewModel()
        vm.addCustomRedaction(rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        let id = vm.redactionRegions.last!.id
        vm.selectRedactionRegion(id: id)
        XCTAssertEqual(vm.selectedRedactionRegionID, id)

        vm.deleteRedactionRegion(id: id)

        XCTAssertNil(vm.selectedRedactionRegionID,
                     "Deleting the selected region must clear selectedRedactionRegionID")
    }

    // MARK: - imageNormalizedPoint regression tests
    //
    // These guard against the coordinate-misalignment bug where drawn redaction
    // boxes landed at the wrong image position because the centering offset,
    // zoom scale, and pan offset were not subtracted from raw touch coordinates.

    /// Touching the image's top-left corner in a centred container must map to (0, 0).
    func testImageNormalizedPointTopLeftCorner() {
        // Image 200×300 centred in a 400×600 container (100 pt margin left/right, 150 top/bottom).
        let result = imageNormalizedPoint(
            CGPoint(x: 100, y: 150),
            imageSize: CGSize(width: 200, height: 300),
            containerSize: CGSize(width: 400, height: 600)
        )
        XCTAssertEqual(result.x, 0, accuracy: 0.0001, "Top-left corner should normalise to x=0")
        XCTAssertEqual(result.y, 0, accuracy: 0.0001, "Top-left corner should normalise to y=0")
    }

    /// Touching the container centre must map to the image centre (0.5, 0.5).
    func testImageNormalizedPointContainerCentreIsImageCentre() {
        let result = imageNormalizedPoint(
            CGPoint(x: 200, y: 300),
            imageSize: CGSize(width: 200, height: 300),
            containerSize: CGSize(width: 400, height: 600)
        )
        XCTAssertEqual(result.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(result.y, 0.5, accuracy: 0.0001)
    }

    /// Touching the image's bottom-right corner must map to (1, 1).
    func testImageNormalizedPointBottomRightCorner() {
        // Image ends at x=300, y=450 in container space.
        let result = imageNormalizedPoint(
            CGPoint(x: 300, y: 450),
            imageSize: CGSize(width: 200, height: 300),
            containerSize: CGSize(width: 400, height: 600)
        )
        XCTAssertEqual(result.x, 1.0, accuracy: 0.0001)
        XCTAssertEqual(result.y, 1.0, accuracy: 0.0001)
    }

    /// At zoom scale=2 with no pan the image fills the container exactly;
    /// the centre touch must still map to (0.5, 0.5).
    func testImageNormalizedPointZoomedIn() {
        // At scale=2 image 200×300 fills a 400×600 container exactly (origin = 0,0).
        let result = imageNormalizedPoint(
            CGPoint(x: 200, y: 300),
            imageSize: CGSize(width: 200, height: 300),
            containerSize: CGSize(width: 400, height: 600),
            scale: 2
        )
        XCTAssertEqual(result.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(result.y, 0.5, accuracy: 0.0001)
    }

    /// Regression: the centre of a drawn box must equal the midpoint of the
    /// start and end touch locations, proving the drag-to-draw gesture now
    /// produces a box centred on where the user actually dragged.
    func testDrawnBoxCentreMatchesTouchMidpoint() {
        let container = CGSize(width: 390, height: 700)
        let imageSize = CGSize(width: 300, height: 500)

        let start = CGPoint(x: 145, y: 150)
        let end   = CGPoint(x: 245, y: 250)

        let s = imageNormalizedPoint(start, imageSize: imageSize, containerSize: container)
        let e = imageNormalizedPoint(end,   imageSize: imageSize, containerSize: container)

        // Centre of the drawn box in normalised space.
        let boxCentreX = min(s.x, e.x) + abs(e.x - s.x) / 2
        let boxCentreY = min(s.y, e.y) + abs(e.y - s.y) / 2

        // Midpoint of the two touch locations, also normalised.
        let mid = imageNormalizedPoint(
            CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2),
            imageSize: imageSize,
            containerSize: container
        )

        XCTAssertEqual(boxCentreX, mid.x, accuracy: 0.0001,
                       "Box centre X must equal the touch-drag midpoint X")
        XCTAssertEqual(boxCentreY, mid.y, accuracy: 0.0001,
                       "Box centre Y must equal the touch-drag midpoint Y")
    }

    /// Touches outside the image bounds return values outside [0,1]; callers
    /// rely on RedactionRegion.clamped() to bring them back in range.
    func testImageNormalizedPointOutsideImageClampable() {
        // Touching the left margin (x=0) of a centred image should give a
        // negative normalised x, which RedactionRegion.clamped() will clip to 0.
        let result = imageNormalizedPoint(
            CGPoint(x: 0, y: 300),
            imageSize: CGSize(width: 200, height: 300),
            containerSize: CGSize(width: 400, height: 600)
        )
        XCTAssertLessThan(result.x, 0, "Touch left of image should produce negative x before clamping")
        let clamped = RedactionRegion.clamped(CGRect(x: result.x, y: result.y, width: 0.1, height: 0.1))
        XCTAssertGreaterThanOrEqual(clamped.minX, 0)
    }

    // MARK: - normalizedDelta scale-correctness tests
    //
    // These guard against the drag-drift bug where move/resize deltas were divided
    // only by imageSize, missing the current zoom `scale` factor.  At scale=1 the
    // bug was invisible; at scale=2 the box moved twice as far as the finger.
    //
    // `normalizedDelta` is private to ZoomableImagePreview, so we test the maths
    // directly through `imageNormalizedPoint` using the same formula the
    // implementation uses: delta = imageNormalizedPoint(end) − imageNormalizedPoint(start).

    /// At scale=1 (no zoom), dragging 20 pt right over a 200 pt wide image should
    /// produce a normalised delta of 0.10 (20 / 200).
    func testNormalizedDeltaScaleOne() {
        let imageSize  = CGSize(width: 200, height: 300)
        let container  = CGSize(width: 400, height: 600)
        let scale: CGFloat = 1
        let pan = CGSize.zero

        let start = CGPoint(x: 200, y: 300)           // container centre
        let end   = CGPoint(x: 220, y: 300)           // 20 pt right

        let s = imageNormalizedPoint(start, imageSize: imageSize, containerSize: container,
                                     scale: scale, panOffset: pan)
        let e = imageNormalizedPoint(end,   imageSize: imageSize, containerSize: container,
                                     scale: scale, panOffset: pan)
        let dx = e.x - s.x
        let dy = e.y - s.y

        XCTAssertEqual(dx,  0.10, accuracy: 0.0001,
                       "20 pt / (1 × 200 pt) must equal 0.10 normalised delta at scale=1")
        XCTAssertEqual(dy,  0.00, accuracy: 0.0001, "Pure horizontal drag must not produce vertical delta")
    }

    /// At scale=2 (pinched in), the same 20 pt finger drag should produce a
    /// normalised delta of 0.05 (20 / (2 × 200)) — half of the scale=1 value.
    /// The old code produced 0.10 regardless of scale, causing a 2× overshoot.
    func testNormalizedDeltaScaleTwo() {
        let imageSize  = CGSize(width: 200, height: 300)
        let container  = CGSize(width: 400, height: 600)
        let scale: CGFloat = 2
        let pan = CGSize.zero   // at scale=2 with no pan the image fills the container exactly

        // At scale=2 the image origin is at (0, 0) — no centering margin left.
        // Container centre (200, 300) maps to normalised (0.5, 0.5).
        let start = CGPoint(x: 200, y: 300)
        let end   = CGPoint(x: 220, y: 300)           // same 20 pt finger drag

        let s = imageNormalizedPoint(start, imageSize: imageSize, containerSize: container,
                                     scale: scale, panOffset: pan)
        let e = imageNormalizedPoint(end,   imageSize: imageSize, containerSize: container,
                                     scale: scale, panOffset: pan)
        let dx = e.x - s.x

        XCTAssertEqual(dx, 0.05, accuracy: 0.0001,
                       "20 pt / (2 × 200 pt) must equal 0.05 at scale=2; old code returned 0.10 (regression)")
    }

    /// With non-zero pan, the delta between two nearby points must be the same as
    /// without pan — pan offset cancels in the subtraction.
    func testNormalizedDeltaPanOffsetCancels() {
        let imageSize  = CGSize(width: 200, height: 300)
        let container  = CGSize(width: 400, height: 600)
        let scale: CGFloat = 2
        let pan = CGSize(width: 50, height: -30)       // arbitrary non-zero pan

        let start = CGPoint(x: 200, y: 300)
        let end   = CGPoint(x: 200, y: 330)            // 30 pt downward drag

        let s = imageNormalizedPoint(start, imageSize: imageSize, containerSize: container,
                                     scale: scale, panOffset: pan)
        let e = imageNormalizedPoint(end,   imageSize: imageSize, containerSize: container,
                                     scale: scale, panOffset: pan)
        let dy = e.y - s.y

        // Expected: 30 / (2 × 300) = 0.05
        XCTAssertEqual(dy, 0.05, accuracy: 0.0001,
                       "Pan offset must cancel in endpoint subtraction; dy must equal 30/(2×300)=0.05")
        XCTAssertEqual(e.x - s.x, 0.0, accuracy: 0.0001, "Pure vertical drag must not produce horizontal delta")
    }

    // MARK: - Style + Color tests

    /// New regions must carry `.solid` and `.black` defaults so existing rendering
    /// paths (which assumed solid black) continue to produce the same output.
    func testRedactionRegionDefaultStyleAndColor() {
        let custom = RedactionRegion.custom(rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        XCTAssertEqual(custom.style, .solid, "Custom regions must default to .solid style")
        XCTAssertEqual(custom.color, .black, "Custom regions must default to .black colour")
    }

    /// Changing a region's style is undoable — one undo step restores the previous style.
    func testChangeRedactionStyleIsUndoable() async {
        let vm = ScrubberViewModel()
        vm.addCustomRedaction(rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        let id = vm.redactionRegions.last!.id
        XCTAssertEqual(vm.redactionRegions.last?.style, .solid)

        vm.changeRedactionStyle(id: id, style: .crosshatch)
        XCTAssertEqual(vm.redactionRegions.first { $0.id == id }?.style, .crosshatch,
                       "Style must update immediately")
        XCTAssertTrue(vm.canUndo, "changeRedactionStyle must push an undo snapshot")

        vm.undoRedaction()
        XCTAssertEqual(vm.redactionRegions.first { $0.id == id }?.style, .solid,
                       "Undo must restore the previous style")
    }

    /// Changing a region's colour is undoable — one undo step restores the previous colour.
    func testChangeRedactionColorIsUndoable() async {
        let vm = ScrubberViewModel()
        vm.addCustomRedaction(rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        let id = vm.redactionRegions.last!.id
        XCTAssertEqual(vm.redactionRegions.last?.color, .black)

        vm.changeRedactionColor(id: id, color: .navy)
        XCTAssertEqual(vm.redactionRegions.first { $0.id == id }?.color, .navy,
                       "Colour must update immediately")
        XCTAssertTrue(vm.canUndo, "changeRedactionColor must push an undo snapshot")

        vm.undoRedaction()
        XCTAssertEqual(vm.redactionRegions.first { $0.id == id }?.color, .black,
                       "Undo must restore the previous colour")
    }

    /// `supportsColor` must be `false` only for `.pixelate`; all other styles support colour.
    func testRedactionStyleSupportsColor() {
        XCTAssertTrue(RedactionStyle.solid.supportsColor)
        XCTAssertTrue(RedactionStyle.crosshatch.supportsColor)
        XCTAssertFalse(RedactionStyle.pixelate.supportsColor,
                       ".pixelate shows source pixels — colour choice is meaningless")
    }

    /// Redacting with a red solid region must produce a red-dominant pixel at the
    /// covered location, proving per-region colour is respected at render time.
    ///
    /// Uses `preferredRange = .standard` to guarantee sRGB byte values so the
    /// assertion thresholds are colour-space–agnostic.
    func testImageRedactorRedColorRegion() async throws {
        // Force standard (sRGB) colour range so byte values are predictable.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20), format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }

        let spec = RedactionSpec(
            rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
            style: .solid,
            color: .red,
            isEnabled: true
        )
        let rendered = await ImageRedactor().redact(image: image, specs: [spec])
        let redacted = try XCTUnwrap(rendered)
        let pixel = try pixelColor(in: redacted, x: 2, y: 2)

        // Red channel must decisively dominate green and blue — hold true in
        // any reasonable colour space conversion.
        XCTAssertGreaterThan(Int(pixel[0]), Int(pixel[1]) * 5,
                             "Red channel must dominate green for a .red region")
        XCTAssertGreaterThan(Int(pixel[0]), Int(pixel[2]) * 5,
                             "Red channel must dominate blue for a .red region")
        XCTAssertGreaterThan(pixel[0], 150,
                             "Red channel byte value must be substantial")
    }

    /// The `redact(image:specs:)` API must return a non-nil image for every style,
    /// including `.pixelate` which uses a CIFilter pre-pass rather than Core Graphics.
    func testImageRedactorAllStylesProduceNonNilImage() async throws {
        let image = try makeImage(color: .white, size: CGSize(width: 40, height: 40))
        for style in RedactionStyle.allCases {
            var region = RedactionRegion.custom(rect: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
            region.style = style
            region.color = .black
            let result = await ImageRedactor().redact(image: image, specs: [region.spec])
            XCTAssertNotNil(result, "redact(image:specs:) must return a non-nil image for style .\(style.rawValue)")
        }
    }

    /// Every `RedactionColor` case must produce a non-nil render for the `.solid`
    /// style, proving all new colour definitions resolve to a valid UIColor.
    func testAllColorsProduceNonNilSolidRender() async throws {
        let image = try makeImage(color: .white, size: CGSize(width: 20, height: 20))
        for color in RedactionColor.allCases {
            let spec = RedactionSpec(
                rect: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8),
                style: .solid,
                color: color,
                isEnabled: true
            )
            let result = await ImageRedactor().redact(image: image, specs: [spec])
            XCTAssertNotNil(result,
                "redact must return a non-nil image for color .\(color.rawValue)")
        }
    }

    /// The light-colour flag must be `true` only for white and yellow, so the UI
    /// renders a dark checkmark on those swatches.
    func testRedactionColorIsLightFlagCorrect() {
        let expectedLight: Set<RedactionColor> = [.white, .yellow]
        for color in RedactionColor.allCases {
            if expectedLight.contains(color) {
                XCTAssertTrue(color.isLight,
                    ".\(color.rawValue) should be flagged as light (needs dark checkmark)")
            } else {
                XCTAssertFalse(color.isLight,
                    ".\(color.rawValue) should NOT be flagged as light")
            }
        }
    }

    // MARK: - Helpers

    private func makeImage(color: UIColor, size: CGSize = CGSize(width: 4, height: 4)) throws -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func pixelColor(in image: UIImage, x: Int, y: Int) throws -> [UInt8] {
        guard let cgImage = image.cgImage else {
            throw XCTSkip("Test image must have CGImage backing.")
        }

        var pixels = [UInt8](repeating: 0, count: 4 * cgImage.width * cgImage.height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels,
            width: cgImage.width,
            height: cgImage.height,
            bitsPerComponent: 8,
            bytesPerRow: 4 * cgImage.width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw XCTSkip("Could not create bitmap context.")
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        let offset = 4 * (y * cgImage.width + x)
        return Array(pixels[offset..<(offset + 4)])
    }
}
