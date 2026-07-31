import CoreGraphics
import Testing
@testable import UsageDock

@MainActor
@Suite("Direct component reordering")
struct DirectReorderInteractionTests {
    private enum Item: String, Hashable {
        case a, b, c, d
    }

    @Test("Only the active drag handle owns press feedback")
    func explicitHandlePressLifecycle() {
        let interaction = DirectReorderInteraction<Item>()

        interaction.setPressing(true, item: .a)
        #expect(interaction.isPressing(.a))
        #expect(!interaction.isPressing(.b))

        // An unrelated handle's cleanup cannot make A flash back to idle.
        interaction.setPressing(false, item: .b)
        #expect(interaction.isPressing(.a))

        interaction.setPressing(false, item: .a)
        #expect(!interaction.isPressing(.a))
    }

    @Test("Vertical stack keeps the full component under the pointer and shifts its vacancy")
    func verticalStackOffsetsAndCommitsOnDrop() throws {
        let interaction = DirectReorderInteraction<Item>()
        interaction.updateFrame(CGRect(x: 0, y: 0, width: 100, height: 100), for: .a)
        interaction.updateFrame(CGRect(x: 0, y: 112, width: 100, height: 80), for: .b)
        interaction.updateFrame(CGRect(x: 0, y: 204, width: 100, height: 120), for: .c)

        interaction.update(
            item: .a,
            location: CGPoint(x: 10, y: 17),
            translation: CGSize(width: 0, height: 7),
            candidates: [.a, .b, .c],
            layout: .vertical(spacing: 12)
        )
        #expect(interaction.isDragging(.a))
        #expect(interaction.offset(for: .a, layout: .vertical(spacing: 12)) == CGSize(width: 0, height: 7))

        interaction.update(
            item: .a,
            location: CGPoint(x: 10, y: 70),
            translation: CGSize(width: 0, height: 60),
            candidates: [.a, .b, .c],
            layout: .vertical(spacing: 12)
        )

        #expect(interaction.offset(for: .a, layout: .vertical(spacing: 12)) == CGSize(width: 0, height: 60))
        #expect(interaction.offset(for: .b, layout: .vertical(spacing: 12)) == CGSize(width: 0, height: -112))
        #expect(interaction.offset(for: .c, layout: .vertical(spacing: 12)) == .zero)

        let destination = try #require(interaction.finish(item: .a))
        #expect(destination.item == .a)
        #expect(destination.target == .b)
        #expect(!interaction.isActive)
    }

    @Test("Grid preview reflows real card heights before committing")
    func gridReflowsCapturedSlots() throws {
        let interaction = DirectReorderInteraction<Item>()
        interaction.updateFrame(CGRect(x: 0, y: 0, width: 100, height: 100), for: .a)
        interaction.updateFrame(CGRect(x: 114, y: 0, width: 100, height: 150), for: .b)
        interaction.updateFrame(CGRect(x: 0, y: 164, width: 100, height: 80), for: .c)
        interaction.updateFrame(CGRect(x: 114, y: 164, width: 100, height: 90), for: .d)

        interaction.update(
            item: .a,
            location: CGPoint(x: 20, y: 10),
            translation: CGSize(width: 10, height: 0),
            candidates: [.a, .b, .c, .d],
            layout: .grid(spacing: 14)
        )
        interaction.update(
            item: .a,
            location: CGPoint(x: 50, y: 204),
            translation: CGSize(width: 40, height: 194),
            candidates: [.a, .b, .c, .d],
            layout: .grid(spacing: 14)
        )

        // Preview order is B, C, A, D. B and C occupy the first row, whose
        // 150pt maximum height leaves the second row at its captured y = 164.
        #expect(interaction.offset(for: .b, layout: .grid(spacing: 14)) == CGSize(width: -114, height: 0))
        #expect(interaction.offset(for: .c, layout: .grid(spacing: 14)) == CGSize(width: 114, height: -164))
        #expect(interaction.offset(for: .d, layout: .grid(spacing: 14)) == .zero)

        let destination = try #require(interaction.finish(item: .a))
        #expect(destination.item == .a)
        #expect(destination.target == .c)
    }

    @Test("Grid target offsets stay stable across pointer-only updates")
    func gridOffsetsRemainStableBetweenDestinations() {
        let interaction = DirectReorderInteraction<Item>()
        interaction.updateFrame(CGRect(x: 0, y: 0, width: 100, height: 100), for: .a)
        interaction.updateFrame(CGRect(x: 114, y: 0, width: 100, height: 100), for: .b)
        interaction.updateFrame(CGRect(x: 0, y: 114, width: 100, height: 100), for: .c)

        interaction.update(
            item: .a,
            location: CGPoint(x: 20, y: 10),
            translation: CGSize(width: 10, height: 0),
            candidates: [.a, .b, .c],
            layout: .grid(spacing: 14)
        )
        interaction.update(
            item: .a,
            location: CGPoint(x: 150, y: 50),
            translation: CGSize(width: 140, height: 40),
            candidates: [.a, .b, .c],
            layout: .grid(spacing: 14)
        )
        let before = interaction.offset(for: .b, layout: .grid(spacing: 14))

        interaction.update(
            item: .a,
            location: CGPoint(x: 160, y: 55),
            translation: CGSize(width: 150, height: 45),
            candidates: [.a, .b, .c],
            layout: .grid(spacing: 14)
        )

        #expect(interaction.offset(for: .b, layout: .grid(spacing: 14)) == before)
    }

    @Test("Dropping outside the component region cancels the persisted move")
    func outsideDropCancelsMove() {
        let interaction = DirectReorderInteraction<Item>()
        interaction.updateFrame(CGRect(x: 0, y: 0, width: 100, height: 100), for: .a)
        interaction.updateFrame(CGRect(x: 0, y: 112, width: 100, height: 100), for: .b)

        interaction.update(
            item: .a,
            location: CGPoint(x: 10, y: 150),
            translation: CGSize(width: 0, height: 140),
            candidates: [.a, .b],
            layout: .vertical(spacing: 12)
        )
        interaction.update(
            item: .a,
            location: CGPoint(x: 500, y: 500),
            translation: CGSize(width: 490, height: 490),
            candidates: [.a, .b],
            layout: .vertical(spacing: 12)
        )

        #expect(interaction.finish(item: .a) == nil)
        #expect(!interaction.isActive)
    }

    @Test("Animated geometry cannot rewrite captured slots during a drag")
    func activeDragFreezesCapturedFrames() {
        let interaction = DirectReorderInteraction<Item>()
        interaction.updateFrame(CGRect(x: 0, y: 0, width: 100, height: 100), for: .a)
        interaction.updateFrame(CGRect(x: 0, y: 112, width: 100, height: 100), for: .b)

        interaction.update(
            item: .a,
            location: CGPoint(x: 10, y: 17),
            translation: CGSize(width: 0, height: 7),
            candidates: [.a, .b],
            layout: .vertical(spacing: 12)
        )

        // Simulate a geometry callback observing B partway through its vacancy
        // animation. It must not become the next ordering reference frame.
        interaction.updateFrame(CGRect(x: 0, y: 70, width: 100, height: 100), for: .b)
        interaction.update(
            item: .a,
            location: CGPoint(x: 10, y: 80),
            translation: CGSize(width: 0, height: 70),
            candidates: [.a, .b],
            layout: .vertical(spacing: 12)
        )

        #expect(interaction.offset(for: .b, layout: .vertical(spacing: 12)) == CGSize(width: 0, height: -112))
    }

    @Test("A stale gesture cleanup cannot cancel a different active item")
    func itemScopedCancellationIgnoresOtherItems() {
        let interaction = DirectReorderInteraction<Item>()
        interaction.updateFrame(CGRect(x: 0, y: 0, width: 100, height: 100), for: .a)
        interaction.updateFrame(CGRect(x: 0, y: 112, width: 100, height: 100), for: .b)

        interaction.update(
            item: .a,
            location: CGPoint(x: 10, y: 17),
            translation: CGSize(width: 0, height: 7),
            candidates: [.a, .b],
            layout: .vertical(spacing: 12)
        )

        interaction.cancel(item: .b)
        #expect(interaction.isDragging(.a))

        interaction.cancel(item: .a)
        #expect(!interaction.isActive)
    }
}
