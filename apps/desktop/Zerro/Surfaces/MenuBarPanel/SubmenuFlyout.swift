//
//  SubmenuFlyout.swift
//  Zerro
//
//  Native-NSMenu-style flyout presentation for the menu-bar dropdown's
//  hover submenus (Model / Microphone / Recent Prompts / Entitlement).
//
//  Why not `.popover`: the system popover chrome is wrong for a submenu
//  — it draws an anchor beak, a ~20pt glass body, and a window-shape
//  mask, none of which can be disabled with public API. Verified on
//  macOS 26: `.presentationBackground(.clear)` removes neither the
//  glass nor the beak, and the private escape hatches
//  (`NSPopover.shouldHideAnchor`, reshaping `NSPopoverFrame`) would
//  take several private calls to defeat the window mask alone. So the
//  flyout is a borderless, non-activating child NSPanel anchored to the
//  row's trailing edge, with the menu container drawn in SwiftUI
//  (SubmenuChrome). The presenting API mirrors `.popover(isPresented:)`
//  so the hover open/close plumbing in MenuBarPanelView is untouched.
//

import AppKit
import SwiftUI

// MARK: - Dismiss action

/// `@Environment(\.dismiss)` only knows about SwiftUI-managed
/// presentations (sheets, popovers); the flyout panel is AppKit-managed,
/// so SubmenuFlyoutPresenter injects this closure instead. Submenu rows
/// call it after a selection to close their flyout (it just flips the
/// `isPresented` binding to false).
private struct SubmenuDismissKey: EnvironmentKey {
    static let defaultValue: @MainActor () -> Void = {}
}

extension EnvironmentValues {
    var submenuDismiss: @MainActor () -> Void {
        get { self[SubmenuDismissKey.self] }
        set { self[SubmenuDismissKey.self] = newValue }
    }
}

// MARK: - SubmenuChrome

/// The shared self-drawn menu container: rounded hairline edge and tight
/// vertical insets. Applied by SubmenuFlyoutPresenter so the four
/// submenus can't drift apart. The BACKGROUND deliberately isn't drawn
/// here: a solid color can't match the dropdown's system glass across
/// wallpapers/appearances, so the presenter puts a real
/// `NSVisualEffectView` (`.menu` material, behind-window blending)
/// underneath this view, masked to the same rounded rect — and AppKit
/// draws the window shadow from that shape. The hairline uses the
/// default circular corner style to hug the AppKit mask (which is a
/// plain rounded rect, not a continuous curve); the row highlights
/// inside remain continuous.
struct SubmenuChrome<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(.vertical, MenuMetrics.containerVerticalPadding)
            .overlay(
                RoundedRectangle(cornerRadius: MenuMetrics.submenuCornerRadius)
                    .strokeBorder(Color.vfHairline, lineWidth: 0.5)
            )
    }
}

// MARK: - Presenting modifier

extension View {
    /// Presents `content` in a chromeless flyout panel at this view's
    /// trailing edge while `isPresented` is true. Drop-in replacement
    /// for the previous `.popover(isPresented:arrowEdge: .trailing)`
    /// call sites — same binding semantics, no system chrome.
    func submenuFlyout<Content: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        background(
            SubmenuFlyoutPresenter(isPresented: isPresented, flyoutContent: content)
        )
    }
}

// MARK: - Presenter

private struct SubmenuFlyoutPresenter<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    @ViewBuilder let flyoutContent: () -> Content

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Read the binding SYNCHRONOUSLY: SwiftUI only re-invokes
        // updateNSView for state it saw read during the update, and the
        // escaping closure below doesn't count — without this line the
        // representable never updates when the binding flips.
        let isPresented = self.isPresented
        let coordinator = context.coordinator
        let rootView = AnyView(
            SubmenuChrome { flyoutContent() }
                .environment(\.submenuDismiss, { self.isPresented = false })
        )
        // Defer one runloop turn: on the first presenting update the
        // anchor view may not be in a window yet, and AppKit window
        // mutation from inside a SwiftUI update is unsafe anyway.
        DispatchQueue.main.async {
            if isPresented {
                coordinator.presentOrUpdate(anchoredTo: nsView, rootView: rootView)
            } else {
                coordinator.dismiss()
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private var panel: NSPanel?
        private var hosting: FlyoutHostingView?
        // Kept so a CONTENT-driven resize (e.g. the async device enumeration
        // in MicrophonePicker, which lands after the panel is first sized) can
        // re-fit the panel without another SwiftUI `updateNSView`.
        private weak var anchor: NSView?
        private weak var parentWindow: NSWindow?
        private var lastFittedSize: NSSize?

        func presentOrUpdate(anchoredTo anchor: NSView, rootView: AnyView) {
            guard let parentWindow = anchor.window else { return }
            self.anchor = anchor
            self.parentWindow = parentWindow

            if let hosting {
                // Already presented: refresh content and re-fit (the
                // device/prompt lists can change while open).
                hosting.rootView = rootView
                layout(anchor: anchor, parentWindow: parentWindow)
                return
            }

            let hosting = FlyoutHostingView(rootView: rootView)
            // When the hosted SwiftUI content changes its ideal size — most
            // commonly MicrophonePicker's devices loading in `onAppear`, AFTER
            // this initial sizing — re-fit the panel so late rows aren't
            // clipped. Deferred a runloop turn: window mutation mustn't happen
            // mid-layout, and `hosting`/`panel` aren't stored yet on the very
            // first invalidation triggered while reading `fittingSize` below.
            hosting.onContentSizeChange = { [weak self] in
                DispatchQueue.main.async { self?.refitToContent() }
            }
            let size = hosting.fittingSize
            let container = NSView(frame: NSRect(origin: .zero, size: size))

            // The same glass the system gives the MenuBarExtra dropdown:
            // a behind-window-blending material, masked to SubmenuChrome's
            // rounded rect. `.active` keeps the blur alive even though the
            // panel never becomes key.
            let effect = NSVisualEffectView(frame: container.bounds)
            effect.material = .menu
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.maskImage = Self.roundedMask(radius: MenuMetrics.submenuCornerRadius)
            effect.autoresizingMask = [.width, .height]
            container.addSubview(effect)

            hosting.frame = container.bounds
            hosting.autoresizingMask = [.width, .height]
            container.addSubview(hosting)

            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.contentView = container
            panel.isOpaque = false
            panel.backgroundColor = .clear
            // AppKit traces the shadow from the effect view's rounded
            // mask — the same native shadow a real menu gets.
            panel.hasShadow = true
            // Follow whatever appearance the dropdown window resolves to
            // so the two glass surfaces can't diverge.
            panel.appearance = parentWindow.appearance
            panel.level = parentWindow.level
            panel.becomesKeyOnlyIfNeeded = true
            self.panel = panel
            self.hosting = hosting

            layout(anchor: anchor, parentWindow: parentWindow)
            parentWindow.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil)
        }

        func dismiss() {
            guard let panel else { return }
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            self.panel = nil
            self.hosting = nil
            self.anchor = nil
            self.parentWindow = nil
            self.lastFittedSize = nil
        }

        /// Re-fit the panel to the hosted content's current ideal size. Driven
        /// by `FlyoutHostingView.onContentSizeChange` so an async content
        /// growth (devices/prompts loading after present) resizes the panel
        /// rather than clipping the new rows. No-ops when the size is unchanged,
        /// which also stops the layout→resize→layout cycle from looping.
        private func refitToContent() {
            guard let anchor, let parentWindow, let hosting, panel != nil else { return }
            guard hosting.fittingSize != lastFittedSize else { return }
            layout(anchor: anchor, parentWindow: parentWindow)
        }

        /// Sizes the panel to the content and pins the flyout to the
        /// parent panel's trailing edge with a slight native-menu
        /// overlap, flipping to the leading edge when the screen runs
        /// out. The panel frame IS the visible chrome rect — the window
        /// shadow is AppKit's, drawn outside the frame.
        private func layout(anchor: NSView, parentWindow: NSWindow) {
            guard let panel, let hosting else { return }
            let chromeSize = hosting.fittingSize
            lastFittedSize = chromeSize

            let anchorRect = parentWindow.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            let parentFrame = parentWindow.frame

            // Trailing placement, overlapping the parent panel edge by
            // 4pt the way a native submenu tucks under its parent menu.
            var chromeX = parentFrame.maxX - 4
            if let screen = parentWindow.screen ?? NSScreen.main,
               chromeX + chromeSize.width > screen.visibleFrame.maxX {
                chromeX = parentFrame.minX + 4 - chromeSize.width
            }

            // First flyout row aligns with the anchor row (chrome top =
            // anchor top + the chrome's own vertical content padding).
            var chromeTop = anchorRect.maxY + MenuMetrics.containerVerticalPadding
            if let screen = parentWindow.screen ?? NSScreen.main {
                let visible = screen.visibleFrame
                chromeTop = min(chromeTop, visible.maxY)
                chromeTop = max(chromeTop, visible.minY + chromeSize.height)
            }

            panel.setFrame(
                NSRect(
                    x: chromeX,
                    y: chromeTop - chromeSize.height,
                    width: chromeSize.width,
                    height: chromeSize.height
                ),
                display: true
            )
            // The shadow shape depends on the masked content; recompute
            // after frame/content changes.
            panel.invalidateShadow()
        }

        /// Stretchable rounded-rect mask for the effect view (the
        /// standard AppKit recipe: a (2r+1)² image with `capInsets` at
        /// the radius so corners stay crisp at any size).
        private static func roundedMask(radius: CGFloat) -> NSImage {
            let edge = radius * 2 + 1
            let mask = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
                NSColor.black.setFill()
                NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
                return true
            }
            mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
            mask.resizingMode = .stretch
            return mask
        }
    }
}

/// Hosting view that responds to the first click even though the flyout
/// panel never becomes key — without this, the first click on a row
/// would only focus the panel instead of selecting.
private final class FlyoutHostingView: NSHostingView<AnyView> {
    /// Invoked when the hosted SwiftUI content's ideal size changes, so the
    /// presenter can re-fit the panel to late-arriving rows (see
    /// `Coordinator.refitToContent`).
    var onContentSizeChange: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onContentSizeChange?()
    }
}
