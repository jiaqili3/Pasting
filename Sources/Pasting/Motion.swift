import AppKit
import QuartzCore

enum Motion {
    static var reduce: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || UserDefaults.standard.bool(forKey: "ForceReduceMotion") }
    /// Bezier approximation of a spring with damping ~0.8 (slight overshoot).
    static let springCurve = CAMediaTimingFunction(controlPoints: 0.3, 1.18, 0.55, 1.0)
    static var hasGlass: Bool { if #available(macOS 26, *) { return !UserDefaults.standard.bool(forKey: "DisableGlass") } else { return false } }
}

/// Root of the panel's content: transparent, and dragging empty space moves the window.
final class DragRootView: NSView {
    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
        ClipboardPanelController.shared.userMovedPanel()
    }
}

/// Builds the rounded panel backdrop: Liquid Glass (macOS 26+) or the vibrancy fallback.
enum PanelBackdrop {
    static func make(frame: NSRect, radius: CGFloat, content: NSView) -> NSView {
        if Motion.hasGlass, #available(macOS 26, *) {
            let g = NSGlassEffectView(frame: frame)
            g.cornerRadius = radius
            g.style = .regular
            g.contentView = content
            g.autoresizingMask = [.width, .height]
            g.wantsLayer = true
            g.layer?.cornerRadius = radius
            g.layer?.cornerCurve = .continuous
            g.layer?.masksToBounds = true
            return g
        }
        let fx = NSVisualEffectView(frame: frame)
        fx.autoresizingMask = [.width, .height]
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        // The mask image clips behind-window vibrancy (layer.cornerRadius alone doesn't).
        fx.maskImage = ClipboardPanelController.roundedMask(radius: radius)
        fx.wantsLayer = true
        fx.layer?.cornerRadius = radius
        fx.layer?.cornerCurve = .continuous
        fx.layer?.masksToBounds = true
        content.frame = fx.bounds
        content.autoresizingMask = [.width, .height]
        fx.addSubview(content)
        return fx
    }
}

/// Trash button that morphs into "Confirm clear?" with a draining countdown bar.
final class ClearButton: NSView {
    var onClick: (() -> Void)?
    private let tint = NSView()
    private var glass: NSView?
    private let icon = NSImageView()
    let label = NSTextField(labelWithString: "")
    private let bar = CALayer()
    private(set) var armed = false
    private var widthC: NSLayoutConstraint!
    static let collapsed: CGFloat = 26

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12; layer?.cornerCurve = .continuous; layer?.masksToBounds = true
        if Motion.hasGlass, #available(macOS 26, *) {
            let g = NSGlassEffectView(); g.cornerRadius = 12; g.style = .regular
            g.translatesAutoresizingMaskIntoConstraints = false
            addSubview(g); glass = g
            pin(g)
        }
        tint.wantsLayer = true
        tint.layer?.backgroundColor = Self.idleColor.cgColor
        tint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tint); pin(tint)
        icon.image = NSImage(systemSymbolName: "trash", accessibilityDescription: L("清空历史"))
        icon.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        icon.wantsLayer = true
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.alphaValue = 0
        label.wantsLayer = true
        label.lineBreakMode = .byClipping
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon); addSubview(label)
        bar.backgroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
        bar.anchorPoint = CGPoint(x: 0, y: 0.5)
        bar.opacity = 0
        layer?.addSublayer(bar)
        widthC = widthAnchor.constraint(equalToConstant: Self.collapsed)
        NSLayoutConstraint.activate([
            widthC, heightAnchor.constraint(equalToConstant: 24),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        toolTip = L("清空历史") + " — " + L("点两次确认，收藏会保留")
        setAccessibilityRole(.button); setAccessibilityLabel(L("清空历史"))
    }
    required init?(coder: NSCoder) { fatalError() }

    private func pin(_ v: NSView) {
        NSLayoutConstraint.activate([v.leadingAnchor.constraint(equalTo: leadingAnchor), v.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     v.topAnchor.constraint(equalTo: topAnchor), v.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }
    static var idleColor: NSColor { Motion.hasGlass ? .clear : NSColor.labelColor.withAlphaComponent(0.06) }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        bar.bounds = CGRect(x: 0, y: 0, width: max(0, bounds.width - 16), height: 2)
        bar.position = CGPoint(x: 8, y: 3)
        CATransaction.commit()
    }
    override func mouseDown(with event: NSEvent) {}            // not a window-drag region
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    var expandedWidth: CGFloat {
        label.stringValue = L("确认清空?")
        return 6 + 16 + 4 + ceil(label.intrinsicContentSize.width) + 10
    }

    func setArmed(_ on: Bool, countdown: TimeInterval) {
        guard on != armed else { return }
        armed = on
        let reduce = Motion.reduce
        let target = on ? expandedWidth : Self.collapsed
        let red = NSColor.systemRed.withAlphaComponent(0.92).cgColor, idle = Self.idleColor.cgColor
        // Width morph (siblings slide because the layout animates).
        if reduce {
            widthC.constant = target; superview?.layoutSubtreeIfNeeded()
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.32
                ctx.timingFunction = Motion.springCurve
                ctx.allowsImplicitAnimation = true
                widthC.animator().constant = target
                superview?.layoutSubtreeIfNeeded()
            }
        }
        // Background crossfade gray -> red.
        if let l = tint.layer {
            let a = CABasicAnimation(keyPath: "backgroundColor")
            a.fromValue = l.presentation()?.backgroundColor ?? l.backgroundColor
            a.toValue = on ? red : idle
            a.duration = reduce ? 0.2 : 0.25
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            l.backgroundColor = on ? red : idle
            l.add(a, forKey: "bg")
        }
        icon.contentTintColor = on ? .white : .secondaryLabelColor
        // Label fade (+ slide in).
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = on ? 0.22 : 0.15
            label.animator().alphaValue = on ? 1 : 0
        }
        if on, !reduce, let ll = label.layer {
            let s = CABasicAnimation(keyPath: "transform.translation.x")
            s.fromValue = -8; s.toValue = 0; s.duration = 0.28; s.timingFunction = Motion.springCurve
            ll.add(s, forKey: "slide")
            // Icon wiggle.
            if let il = icon.layer {
                let w = CAKeyframeAnimation(keyPath: "transform.translation.x")
                w.values = [0, -2, 2, -1.5, 1, 0]; w.duration = 0.35
                il.add(w, forKey: "wiggle")
            }
        }
        // Countdown bar drains over the confirm window.
        bar.removeAllAnimations()
        if on {
            bar.opacity = 1
            let d = CABasicAnimation(keyPath: "transform.scale.x")
            d.fromValue = 1; d.toValue = 0; d.duration = countdown
            d.timingFunction = CAMediaTimingFunction(name: .linear)
            d.fillMode = .forwards; d.isRemovedOnCompletion = false
            bar.add(d, forKey: "countdown")
        } else {
            bar.opacity = 0
        }
    }

    // Test probes (presentation-layer values = what's on screen mid-animation).
    var probeWidth: CGFloat { layer?.presentation()?.bounds.width ?? bounds.width }
    var probeRed: CGFloat {
        guard let c = tint.layer?.presentation()?.backgroundColor ?? tint.layer?.backgroundColor,
              let ns = NSColor(cgColor: c)?.usingColorSpace(.sRGB) else { return 0 }
        return ns.redComponent * ns.alphaComponent
    }
    var probeLabelAlpha: Float { label.layer?.presentation()?.opacity ?? Float(label.alphaValue) }
    var probeBar: CGFloat { (bar.presentation()?.value(forKeyPath: "transform.scale.x") as? CGFloat) ?? 0 }
}

/// "Cleared N · Undo" capsule with spring slide-up and a countdown bar.
final class UndoToastView: NSView {
    let label = NSTextField(labelWithString: "")
    let undo = NSButton(title: "", target: nil, action: nil)
    private let bar = CALayer()
    private var bg: NSView?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 15; layer?.cornerCurve = .continuous; layer?.masksToBounds = true
        if Motion.hasGlass, #available(macOS 26, *) {
            let g = NSGlassEffectView(); g.cornerRadius = 15; g.style = .regular
            g.translatesAutoresizingMaskIntoConstraints = false; addSubview(g); bg = g
            NSLayoutConstraint.activate([g.leadingAnchor.constraint(equalTo: leadingAnchor), g.trailingAnchor.constraint(equalTo: trailingAnchor),
                                         g.topAnchor.constraint(equalTo: topAnchor), g.bottomAnchor.constraint(equalTo: bottomAnchor)])
        } else {
            layer?.borderWidth = 1
        }
        let icon = NSImageView(image: NSImage(systemSymbolName: "trash", accessibilityDescription: nil)!)
        icon.contentTintColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 12, weight: .medium)
        undo.isBordered = false
        undo.font = .systemFont(ofSize: 12, weight: .semibold)
        undo.contentTintColor = .controlAccentColor
        let stack = NSStackView(views: [icon, label, undo])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 30),
        ])
        bar.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
        bar.anchorPoint = CGPoint(x: 0, y: 0.5)
        layer?.addSublayer(bar)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        if bg == nil {
            layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.97).cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        bar.bounds = CGRect(x: 0, y: 0, width: max(0, bounds.width - 30), height: 2)
        bar.position = CGPoint(x: 15, y: 2)
        CATransaction.commit()
    }

    func present(duration: TimeInterval) {
        isHidden = false
        layoutSubtreeIfNeeded()
        let reduce = Motion.reduce
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { $0.duration = reduce ? 0.2 : 0.22; self.animator().alphaValue = 1 }
        if !reduce, let l = layer {
            let s = CASpringAnimation(keyPath: "transform.translation.y")
            s.fromValue = -22; s.toValue = 0
            s.damping = 16; s.stiffness = 220; s.mass = 1
            s.duration = s.settlingDuration
            l.add(s, forKey: "slideUp")
        }
        bar.removeAllAnimations()
        let d = CABasicAnimation(keyPath: "transform.scale.x")
        d.fromValue = 1; d.toValue = 0; d.duration = duration
        d.fillMode = .forwards; d.isRemovedOnCompletion = false
        bar.add(d, forKey: "countdown")
    }

    func dismiss() {
        guard !isHidden else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; self.animator().alphaValue = 0 }) { [weak self] in
            guard let self, self.alphaValue < 0.01 else { return }
            self.isHidden = true
            self.bar.removeAllAnimations()
        }
    }

    var probeAlpha: Float { layer?.presentation()?.opacity ?? Float(alphaValue) }
    var probeOffsetY: CGFloat { (layer?.presentation()?.value(forKeyPath: "transform.translation.y") as? CGFloat) ?? 0 }
}
