import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import Yafie

@MainActor
struct SnipEditorModelTests {
    /// In memory, so the tests neither change Yafie's settings nor leave files behind
    private let settings = MemorySettings()

    private func model() -> SnipEditorModel {
        SnipEditorModel(snip: Snip(image: SnipImages.plain(), scale: 2), defaults: settings)
    }

    private func draw(_ model: SnipEditorModel, from start: CGPoint, to end: CGPoint, shift: Bool = false) {
        model.begin(at: start)
        model.move(to: end, constrained: shift)
        model.end()
    }

    @Test func startsWithAThinRedBox() {
        let model = model()
        #expect(model.tool == .box && model.color == .red && model.thickness == .thin && model.textSize == 16)
        #expect(!model.canUndo && !model.canRedo && !model.hasUnsavedShapes && model.selected == nil)
    }

    @Test func aDragDrawsWithTheCurrentToolColorAndThickness() {
        let model = model()
        model.tool = .arrow
        model.color = .blue
        model.thickness = .thick
        model.begin(at: CGPoint(x: 10, y: 10))
        model.move(to: CGPoint(x: 60, y: 30), constrained: false)
        #expect(model.drawing?.end == CGPoint(x: 60, y: 30))
        #expect(model.shapes.isEmpty)
        model.end()
        #expect(model.drawing == nil)
        #expect(model.shapes == [Annotation(kind: .arrow, color: .blue, thickness: .thick, start: CGPoint(x: 10, y: 10),
                                            end: CGPoint(x: 60, y: 30))])
    }

    @Test func aDragShorterThanFourPointsMakesNoShape() {
        let model = model()
        // 4 points is 8 pixels at a Retina snip's scale
        draw(model, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 17, y: 10))
        #expect(model.shapes.isEmpty)
        #expect(!model.canUndo)
        draw(model, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 18, y: 10))
        #expect(model.shapes.count == 1)
    }

    @Test func shiftConstrainsWhileDrawing() {
        let model = model()
        model.tool = .line
        draw(model, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 110, y: 14), shift: true)
        #expect(abs((model.shapes.first?.end.y ?? 0) - 10) < 1e-9)
    }

    @Test func undoAndRedo() {
        let model = model()
        for x in [100.0, 200, 300] { draw(model, from: CGPoint(x: x, y: 10), to: CGPoint(x: x, y: 100)) }
        model.undo()
        model.undo()
        #expect(model.shapes.count == 1)
        model.redo()
        #expect(model.shapes.count == 2)
        #expect(model.canRedo)
        draw(model, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 150, y: 150))
        #expect(model.shapes.count == 3)
        #expect(!model.canRedo)
        #expect(model.shapes.last?.start == CGPoint(x: 50, y: 50))
    }

    @Test func copyOrSaveClearsTheChangedFlag() {
        let model = model()
        draw(model, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 100, y: 100))
        #expect(model.hasUnsavedShapes)
        model.kept()
        #expect(!model.hasUnsavedShapes)
        draw(model, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 100, y: 100))
        #expect(model.hasUnsavedShapes)
        // With every shape undone there's nothing to lose
        model.undo()
        model.undo()
        #expect(!model.hasUnsavedShapes)
    }

    @Test func switchingThicknessLeavesDrawnShapesAlone() {
        let model = model()
        draw(model, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 100, y: 100))
        model.thickness = .thick
        #expect(model.shapes.first?.thickness == .thin)
    }

    @Test func theHighlighterHasItsOwnColorStartingYellow() {
        let model = model()
        model.tool = .highlight
        #expect(model.color == .yellow)
        model.color = .green
        model.tool = .arrow
        #expect(model.color == .red)
        model.color = .blue
        model.tool = .highlight
        #expect(model.color == .green)
        draw(model, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 100, y: 100))
        #expect(model.shapes.last?.kind == .highlight && model.shapes.last?.color == .green)

        let next = self.model()
        #expect(next.color == .green)  // still on the highlighter
        next.tool = .box
        #expect(next.color == .blue)
    }

    @Test func remembersTheLastToolColorThicknessAndSize() {
        let first = model()
        first.tool = .arrow
        first.color = .yellow
        first.thickness = .thick
        first.textSize = 12
        let second = model()
        #expect(second.tool == .arrow && second.color == .yellow && second.thickness == .thick)
        #expect(second.textSize == 12)
    }

    @Test func aTextSizeThatsNoLongerOfferedGoesBackTo16() {
        settings.set("18", forKey: "snipTextSize")
        #expect(model().textSize == 16)
        settings.set("24", forKey: "snipTextSize")
        #expect(model().textSize == 24)
    }

    @Test func theBlurToolBlursTheAreaDraggedAcross() throws {
        let model = SnipEditorModel(snip: Snip(image: SnipImages.halves(), scale: 2), defaults: settings)
        model.tool = .blur
        draw(model, from: CGPoint(x: 150, y: 100), to: CGPoint(x: 250, y: 200))
        let blur = try #require(model.shapes.first)
        #expect(blur.kind == .blur)
        #expect(blur.rect == CGRect(x: 150, y: 100, width: 100, height: 100))
        // The sharp edge down the middle of the snip is gray where it's blurred
        let gray = try #require(model.rendered().map { SnipImages.pixel($0, 198, 150)[0] })
        #expect(gray > 0.1 && gray < 0.9)
    }

    @Test func theEraserTakesAwayTheShapeClickedOn() {
        let model = model()
        draw(model, from: CGPoint(x: 100, y: 50), to: CGPoint(x: 300, y: 250))
        model.tool = .line
        draw(model, from: CGPoint(x: 20, y: 280), to: CGPoint(x: 380, y: 280))
        model.tool = .eraser
        model.erase(at: CGPoint(x: 200, y: 284), slop: 8)
        #expect(model.shapes.map(\.kind) == [.box])
        // A box is only its edges
        model.erase(at: CGPoint(x: 200, y: 150), slop: 8)
        #expect(model.shapes.count == 1)
        model.erase(at: CGPoint(x: 104, y: 150), slop: 8)
        #expect(model.shapes.isEmpty && !model.hasUnsavedShapes)
        model.undo()
        model.undo()
        #expect(model.shapes.map(\.kind) == [.box, .line] && model.hasUnsavedShapes)
    }

    @Test func theEraserTakesTheShapeOnTop() {
        let model = model()
        model.tool = .line
        draw(model, from: CGPoint(x: 10, y: 100), to: CGPoint(x: 390, y: 100))
        model.color = .blue
        draw(model, from: CGPoint(x: 200, y: 10), to: CGPoint(x: 200, y: 290))
        model.tool = .eraser
        model.erase(at: CGPoint(x: 200, y: 100), slop: 8)
        #expect(model.shapes.map(\.color) == [.red])
    }

    @Test func theEraserTakesText() {
        let model = model()
        model.tool = .text
        model.beginText(at: CGPoint(x: 40, y: 30))
        model.updateText("Look here")
        model.commitText()
        model.tool = .eraser
        model.erase(at: CGPoint(x: 60, y: 45), slop: 8)
        #expect(model.shapes.isEmpty)
    }

    @Test func aClickWithTheEraserOnNothingChangesNothing() {
        let model = model()
        draw(model, from: CGPoint(x: 100, y: 50), to: CGPoint(x: 300, y: 250))
        model.kept()
        model.tool = .eraser
        model.erase(at: CGPoint(x: 20, y: 20), slop: 8)
        #expect(model.shapes.count == 1 && !model.hasUnsavedShapes)
        model.undo()
        #expect(model.shapes.isEmpty && !model.canUndo)
    }

    @Test func theEraserPointsAtWhatAClickWouldTake() {
        let model = model()
        let reach = SnipEditorModel.Reach(shape: 8, handle: 14)
        draw(model, from: CGPoint(x: 100, y: 50), to: CGPoint(x: 300, y: 250))
        model.point(at: CGPoint(x: 100, y: 150), reach: reach)
        #expect(model.erasable == nil && model.hovered == 0)  // only the eraser points
        model.tool = .eraser
        #expect(model.erasable == 0)
        model.point(at: CGPoint(x: 200, y: 150), reach: reach)
        #expect(model.erasable == nil)
        model.point(at: CGPoint(x: 300, y: 150), reach: reach)
        #expect(model.erasable == 0)
        model.erase(at: CGPoint(x: 300, y: 150), slop: 8)
        #expect(model.erasable == nil)
        model.undo()
        #expect(model.erasable == 0)
        model.point(at: nil, reach: reach)
        #expect(model.erasable == nil)
    }

    @Test func theNextSnipStartsWithTheLastToolThatDraws() {
        let first = model()
        first.tool = .arrow
        first.tool = .eraser
        #expect(model().tool == .arrow)
        first.tool = .blur
        #expect(model().tool == .blur)
    }

    @Test func blursHaveNoColorAndTheEraserNoOptions() {
        #expect(!SnipTool.blur.hasColor && !SnipTool.blur.hasThickness)
        #expect(!SnipTool.eraser.hasColor && !SnipTool.eraser.hasThickness)
        #expect(SnipTool.text.hasColor && !SnipTool.text.hasThickness)
        #expect(SnipTool.highlight.hasColor && !SnipTool.highlight.hasThickness)
        #expect(SnipTool.allCases.filter(\.hasThickness) == [.box, .line, .arrow])
        #expect(Annotation.Kind.allCases.allSatisfy { SnipTool($0).kind == $0 })
    }

    @Test func rendersItsShapesAtFullResolution() {
        let model = model()
        draw(model, from: CGPoint(x: 100, y: 50), to: CGPoint(x: 300, y: 250))
        let image = model.rendered()
        #expect(image?.width == 400 && image?.height == 300)
        #expect(image.map { SnipImages.isRed(SnipImages.pixel($0, 100, 150)) } == true)
    }
}

@MainActor
struct SnipEditorTextTests {
    /// In memory, so the tests neither change Yafie's settings nor leave files behind
    private let settings = MemorySettings()

    private func model() -> SnipEditorModel {
        let model = SnipEditorModel(snip: Snip(image: SnipImages.plain(), scale: 2), defaults: settings)
        model.tool = .text
        return model
    }


    @Test func returnPlacesTheText() {
        let model = model()
        model.beginText(at: CGPoint(x: 40, y: 30))
        #expect(model.isEditingText)
        model.updateText("Look here")
        model.commitText()
        #expect(!model.isEditingText)
        #expect(model.shapes == [Annotation(kind: .text, color: .red, thickness: .thin, start: CGPoint(x: 40, y: 30),
                                            end: CGPoint(x: 40, y: 30), text: "Look here", textSize: 16)])
        #expect(model.canUndo && model.hasUnsavedShapes)
    }

    @Test func blankTextIsDropped() {
        let model = model()
        model.beginText(at: CGPoint(x: 40, y: 30))
        model.updateText("   ")
        model.commitText()
        #expect(model.shapes.isEmpty && !model.canUndo)
    }

    @Test func escDropsTheText() {
        let model = model()
        model.beginText(at: CGPoint(x: 40, y: 30))
        model.updateText("Never mind")
        model.cancelText()
        #expect(model.shapes.isEmpty && !model.isEditingText)
    }

    @Test func clickingElsewherePlacesItAndStartsAnother() {
        let model = model()
        model.beginText(at: CGPoint(x: 40, y: 30))
        model.updateText("One")
        model.beginText(at: CGPoint(x: 200, y: 100))
        #expect(model.shapes.map(\.text) == ["One"])
        #expect(model.draft?.start == CGPoint(x: 200, y: 100))
    }

    @Test func switchingToolsPlacesIt() {
        let model = model()
        model.beginText(at: CGPoint(x: 40, y: 30))
        model.updateText("One")
        model.tool = .arrow
        #expect(model.shapes.map(\.text) == ["One"] && !model.isEditingText)
    }

    @Test func colorAndSizeApplyToTheTextBeingTyped() {
        let model = model()
        model.beginText(at: CGPoint(x: 40, y: 30))
        model.color = .blue
        model.textSize = 12
        #expect(model.draft?.color == .blue && model.draft?.textSize == 12)
    }

    @Test func textUsesThePenColorNotTheHighlighters() {
        let model = model()
        model.tool = .highlight
        model.color = .green
        model.tool = .text
        #expect(model.color == .red)
    }

    @Test func dragsDontDrawWithTheTextTool() {
        let model = model()
        model.begin(at: CGPoint(x: 10, y: 10))
        model.move(to: CGPoint(x: 100, y: 100), constrained: false)
        model.end()
        #expect(model.shapes.isEmpty)
    }
}

@MainActor
struct SnipMenuTests {
    private func items(_ menu: NSMenu) -> [NSMenuItem] { menu.items.compactMap(\.submenu).flatMap(\.items) }

    @Test func commandQClosesTheEditorsNotYafie() throws {
        _ = NSApplication.shared
        let editors = SnipEditors()
        let items = items(SnipMenu.make(editors: editors))
        let commandQ = try #require(items.first { $0.keyEquivalent == "q" && $0.keyEquivalentModifierMask == .command })
        #expect(commandQ.action == #selector(SnipEditors.quitEditors(_:)))
        #expect(commandQ.target === editors)
        let quit = try #require(items.first { $0.action == #selector(NSApplication.terminate(_:)) })
        #expect(quit.keyEquivalent.isEmpty)
    }

    @Test func everySingleKeyIsDifferent() {
        let keys = SnipTool.allCases.map(\.key) + Annotation.Color.allCases.map(\.key) + ["w", SnipMenu.deleteKey]
        #expect(Set(keys).count == keys.count)
        #expect(Annotation.Color.allCases.map(\.key) == ["1", "2", "3", "4", "5", "6"])
    }

    @Test func theDeleteKeyDeletesOnlyWhileSingleKeysAreOn() throws {
        _ = NSApplication.shared
        let menu = SnipMenu.make()
        NSApp.mainMenu = menu
        defer { NSApp.mainMenu = nil }
        let delete = try #require(items(menu).first { $0.title == "Delete" })
        #expect(delete.action == #selector(SnipEditorController.deleteShape(_:)) && delete.keyEquivalent.isEmpty)
        SnipMenu.setSingleKeys(true)
        #expect(delete.keyEquivalent == "\u{8}" && delete.keyEquivalentModifierMask.isEmpty)
        SnipMenu.setSingleKeys(false)
        #expect(delete.keyEquivalent.isEmpty)
    }

    @Test func singleKeysOnlyWhileTurnedOn() throws {
        _ = NSApplication.shared
        let menu = SnipMenu.make()
        NSApp.mainMenu = menu
        defer { NSApp.mainMenu = nil }
        let box = try #require(items(menu).first { $0.title == "Box" })
        #expect(box.keyEquivalent.isEmpty)
        SnipMenu.setSingleKeys(true)
        #expect(box.keyEquivalent == "r" && box.keyEquivalentModifierMask.isEmpty)
        SnipMenu.setSingleKeys(false)
        #expect(box.keyEquivalent.isEmpty)
    }
}

@MainActor
struct SnipSidebarTests {
    @Test func fitsTheWindowsSmallestSize() {
        _ = NSApplication.shared
        let model = SnipEditorModel(snip: Snip(image: SnipImages.plain(), scale: 2), defaults: MemorySettings())
        let size = NSHostingView(rootView: SnipSidebar(model: model, copy: {}, save: {})).fittingSize
        print("The snip editor's sidebar takes \(size.width) by \(size.height) points")
        #expect(size.width <= SnipEditorLayout.sidebarWidth)
        #expect(size.height + SnipEditorLayout.chrome.height <= SnipEditorLayout.minimumHeight)
    }
}

@MainActor
struct SnipSelectionTests {
    /// In memory, so the tests neither change Yafie's settings nor leave files behind
    private let settings = MemorySettings()
    /// 4 points from a shape and 7 from a handle, at 2 pixels a point, as the canvas has them at actual size
    private let reach = SnipEditorModel.Reach(shape: 8, handle: 14)

    private func model(_ tool: SnipTool = .box) -> SnipEditorModel {
        let model = SnipEditorModel(snip: Snip(image: SnipImages.plain(), scale: 2), defaults: settings)
        model.tool = tool
        return model
    }

    /// A press on the snip, dragged and let go
    private func drag(_ model: SnipEditorModel, from start: CGPoint, to end: CGPoint, shift: Bool = false) {
        model.pressDown(at: start, onSnip: true, reach: reach)
        model.pressMoved(to: start, constrained: shift)
        model.pressMoved(to: end, constrained: shift)
        model.pressUp()
    }

    private func click(_ model: SnipEditorModel, at point: CGPoint) { drag(model, from: point, to: point) }

    /// A box from 100, 50 to 300, 250
    private func boxed(_ tool: SnipTool = .box) -> SnipEditorModel {
        let model = model(.box)
        drag(model, from: CGPoint(x: 100, y: 50), to: CGPoint(x: 300, y: 250))
        model.tool = tool
        return model
    }

    @Test func aDragOnNothingDrawsWithTheTool() {
        let model = boxed(.line)
        drag(model, from: CGPoint(x: 20, y: 280), to: CGPoint(x: 380, y: 280))
        #expect(model.shapes.map(\.kind) == [.box, .line] && model.selected == nil)
    }

    @Test func aClickOnAShapeSelectsItAndChangesNothing() {
        let model = boxed()
        click(model, at: CGPoint(x: 102, y: 150))
        #expect(model.selected == 0 && model.shapes.count == 1 && !model.isGrabbing)
        // Only the box's drawing to undo
        model.undo()
        #expect(model.shapes.isEmpty && !model.canUndo && model.selected == nil)
    }

    @Test func aClickOnNothingLetsGoOfIt() {
        let model = boxed()
        click(model, at: CGPoint(x: 102, y: 150))
        click(model, at: CGPoint(x: 200, y: 150))
        #expect(model.selected == nil && model.shapes.count == 1)
    }

    @Test func draggingAShapeMovesItAsOneStepToUndo() {
        let model = boxed()
        drag(model, from: CGPoint(x: 100, y: 150), to: CGPoint(x: 130, y: 170))
        #expect(model.selected == 0 && model.shapes.first?.rect == CGRect(x: 130, y: 70, width: 200, height: 200))
        model.undo()
        #expect(model.shapes.first?.rect == CGRect(x: 100, y: 50, width: 200, height: 200) && model.selected == 0)
        model.redo()
        #expect(model.shapes.first?.rect == CGRect(x: 130, y: 70, width: 200, height: 200))
    }

    @Test func shiftMovesItStraight() {
        let model = boxed()
        drag(model, from: CGPoint(x: 100, y: 150), to: CGPoint(x: 130, y: 160), shift: true)
        #expect(model.shapes.first?.rect == CGRect(x: 130, y: 50, width: 200, height: 200))
    }

    @Test func draggingAHandleOfTheSelectedShapeResizesIt() {
        let model = boxed()
        click(model, at: CGPoint(x: 102, y: 150))
        drag(model, from: CGPoint(x: 298, y: 248), to: CGPoint(x: 350, y: 280))
        #expect(model.shapes.first?.rect == CGRect(x: 100, y: 50, width: 252, height: 232))
        drag(model, from: CGPoint(x: 352, y: 282), to: CGPoint(x: 360, y: 270), shift: true)
        #expect(model.shapes.first?.rect == CGRect(x: 100, y: 50, width: 260, height: 260))
        #expect(model.canUndo && model.selected == 0)
    }

    @Test func theCornerOfAShapeThatIsntSelectedMovesIt() {
        let model = boxed()
        drag(model, from: CGPoint(x: 300, y: 250), to: CGPoint(x: 310, y: 260))
        #expect(model.shapes.first?.rect == CGRect(x: 110, y: 60, width: 200, height: 200))
    }

    @Test func aLinesEndsAreItsHandles() {
        let model = model(.line)
        drag(model, from: CGPoint(x: 20, y: 280), to: CGPoint(x: 380, y: 280))
        click(model, at: CGPoint(x: 200, y: 281))
        drag(model, from: CGPoint(x: 378, y: 280), to: CGPoint(x: 300, y: 200))
        #expect(model.shapes.first?.start == CGPoint(x: 20, y: 280))
        #expect(model.shapes.first?.end == CGPoint(x: 300 + 2, y: 200))
    }

    @Test func theOptionsChangeTheSelectedShapeAndTheNextOne() {
        let model = boxed()
        click(model, at: CGPoint(x: 102, y: 150))
        model.color = .blue
        model.thickness = .thick
        #expect(model.shapes.first?.color == .blue && model.shapes.first?.thickness == .thick)
        model.undo()
        #expect(model.shapes.first?.color == .blue && model.shapes.first?.thickness == .thin)
        model.undo()
        #expect(model.shapes.first?.color == .red)
        click(model, at: CGPoint(x: 200, y: 150))
        drag(model, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 60, y: 40))
        #expect(model.shapes.last?.color == .blue && model.shapes.last?.thickness == .thick)
    }

    @Test func theOptionsShowTheSelectedShapes() {
        let model = boxed()
        model.color = .green
        model.thickness = .thick
        click(model, at: CGPoint(x: 102, y: 150))
        #expect(model.color == .red && model.thickness == .thin && model.options == .box)
        click(model, at: CGPoint(x: 200, y: 150))
        #expect(model.color == .green && model.thickness == .thick)
    }

    @Test func aDragInsideAHighlightDrawsOnItAndOneOnItsEdgeMovesIt() {
        let model = model(.highlight)
        drag(model, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 200, y: 60))
        model.tool = .arrow
        drag(model, from: CGPoint(x: 100, y: 40), to: CGPoint(x: 300, y: 200))
        #expect(model.shapes.map(\.kind) == [.highlight, .arrow] && model.selected == nil)
        model.point(at: CGPoint(x: 60, y: 40), reach: reach)
        #expect(model.hovered == nil)
        model.point(at: CGPoint(x: 60, y: 57), reach: reach)
        #expect(model.hovered == 0)
        drag(model, from: CGPoint(x: 60, y: 57), to: CGPoint(x: 70, y: 67))
        #expect(model.selected == 0 && model.shapes.first?.rect == CGRect(x: 30, y: 30, width: 180, height: 40))
        // Once it's selected, from anywhere on it
        model.point(at: CGPoint(x: 60, y: 50), reach: reach)
        #expect(model.hovered == 0)
        drag(model, from: CGPoint(x: 60, y: 50), to: CGPoint(x: 50, y: 40))
        #expect(model.shapes.first?.rect == CGRect(x: 20, y: 20, width: 180, height: 40))
        #expect(model.shapes.count == 2)
    }

    @Test func aSelectedHighlightHasTheHighlightersOptions() {
        let model = model(.highlight)
        drag(model, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 200, y: 60))
        model.tool = .arrow
        click(model, at: CGPoint(x: 100, y: 58))
        #expect(model.options == .highlight && model.color == .yellow && !model.options.hasThickness)
        model.color = .green
        #expect(model.shapes.first?.color == .green)
        // The highlighter's color, not the pen's
        click(model, at: CGPoint(x: 300, y: 200))
        #expect(model.color == .red)
        model.tool = .highlight
        #expect(model.color == .green)
    }

    @Test func aSelectedTextTakesATextSize() {
        let model = model(.text)
        model.beginText(at: CGPoint(x: 40, y: 30))
        model.updateText("Look here")
        model.commitText()
        // A click on it picks it up instead of starting another
        click(model, at: CGPoint(x: 60, y: 45))
        #expect(model.selected == 0 && !model.isEditingText && model.options == .text)
        model.textSize = 24
        #expect(model.shapes.first?.textSize == 24 && model.shapes.count == 1)
        click(model, at: CGPoint(x: 300, y: 200))
        #expect(model.isEditingText && model.draft?.start == CGPoint(x: 300, y: 200) && model.draft?.textSize == 24)
    }

    @Test func aClickWhileTypingPlacesTheText() {
        let model = model(.text)
        click(model, at: CGPoint(x: 40, y: 30))
        model.updateText("One")
        click(model, at: CGPoint(x: 200, y: 150))
        #expect(model.shapes.map(\.text) == ["One"] && model.draft?.start == CGPoint(x: 200, y: 150))
        model.updateText("Two")
        model.pressDown(at: CGPoint(x: 400, y: 150), onSnip: false, reach: reach)
        model.pressUp()
        #expect(model.shapes.map(\.text) == ["One", "Two"] && !model.isEditingText)
    }

    @Test func deleteTakesAwayTheSelectedShape() {
        let model = boxed()
        drag(model, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 60, y: 40))
        model.deleteSelected()
        #expect(model.shapes.count == 2)
        click(model, at: CGPoint(x: 102, y: 150))
        model.deleteSelected()
        #expect(model.shapes.map(\.rect) == [CGRect(x: 20, y: 20, width: 40, height: 20)] && model.selected == nil)
        model.undo()
        #expect(model.shapes.count == 2 && model.selected == nil)
    }

    @Test func choosingAToolLetsGoOfTheSelection() {
        let model = boxed()
        click(model, at: CGPoint(x: 102, y: 150))
        model.tool = .arrow
        #expect(model.selected == nil)
    }

    @Test func theEraserErasesInsteadOfSelecting() {
        let model = boxed(.eraser)
        click(model, at: CGPoint(x: 102, y: 150))
        #expect(model.shapes.isEmpty && model.selected == nil)
    }

    @Test func pressesOffTheSnipDoNothing() {
        let model = boxed()
        click(model, at: CGPoint(x: 102, y: 150))
        model.pressDown(at: CGPoint(x: 0, y: 150), onSnip: false, reach: reach)
        model.pressMoved(to: CGPoint(x: 100, y: 200), constrained: false)
        model.pressUp()
        #expect(model.shapes.count == 1 && model.selected == nil)
    }

    @Test func aPressThatNeverEndedEndsWhenTheNextOneStarts() {
        let model = model()
        model.pressDown(at: CGPoint(x: 100, y: 50), onSnip: true, reach: reach)
        model.pressMoved(to: CGPoint(x: 300, y: 250), constrained: false)
        #expect(model.pressStart == CGPoint(x: 100, y: 50))
        model.pressDown(at: CGPoint(x: 20, y: 20), onSnip: true, reach: reach)
        #expect(model.shapes.count == 1 && model.pressStart == CGPoint(x: 20, y: 20))
        model.pressUp()
        #expect(model.pressStart == nil)
    }

    @Test func thePointerFindsShapesAndTheSelectedShapesHandles() {
        let model = boxed()
        model.point(at: CGPoint(x: 300, y: 250), reach: reach)
        #expect(model.hovered == 0 && model.hoveredHandle == nil)
        click(model, at: CGPoint(x: 102, y: 150))
        model.point(at: CGPoint(x: 296, y: 247), reach: reach)
        #expect(model.hoveredHandle == 2)
        model.point(at: CGPoint(x: 200, y: 150), reach: reach)
        #expect(model.hovered == nil && model.hoveredHandle == nil)
        model.pressDown(at: CGPoint(x: 102, y: 150), onSnip: true, reach: reach)
        #expect(model.isGrabbing)
        model.pressUp()
        #expect(!model.isGrabbing)
    }
}
