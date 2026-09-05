//
//  SelectionHandleView.swift
//  rootshell
//
//  Lollipop-style visual handles for text selection boundaries.
//  Only used on touch devices (iOS/iPadOS), excluded from Mac Catalyst.
//  Dragging is handled by pan gestures attached to these handle views.
//

#if !targetEnvironment(macCatalyst)

import UIKit

extension Ghostty {

    enum SelectionHandlePosition {
        case start
        case end
    }

    /// A lollipop-style selection handle: circle + stem line. Visual only.
    class SelectionHandleView: UIView {

        static let circleDiameter: CGFloat = 14
        static let lineWidth: CGFloat = 2.5
        static let totalWidth: CGFloat = 22
        static let defaultStemHeight: CGFloat = 20

        let position: SelectionHandlePosition
        var stemHeight: CGFloat = SelectionHandleView.defaultStemHeight {
            didSet {
                guard oldValue != stemHeight else { return }
                invalidateIntrinsicContentSize()
                setNeedsLayout()
            }
        }

        private let stemLayer = CAShapeLayer()
        private let circleLayer = CAShapeLayer()

        init(position: SelectionHandlePosition) {
            self.position = position
            super.init(frame: CGRect(
                x: 0, y: 0,
                width: Self.totalWidth,
                height: Self.defaultStemHeight + Self.circleDiameter
            ))
            isUserInteractionEnabled = true
            backgroundColor = .clear
            setupLayers()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) not supported")
        }

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            bounds.insetBy(dx: -26, dy: -26).contains(point)
        }

        override var intrinsicContentSize: CGSize {
            CGSize(width: Self.totalWidth, height: stemHeight + Self.circleDiameter)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            updatePaths()
        }

        private func setupLayers() {
            let tint = UIColor.systemBlue
            stemLayer.strokeColor = tint.cgColor
            stemLayer.lineWidth = Self.lineWidth
            stemLayer.lineCap = .round
            layer.addSublayer(stemLayer)

            circleLayer.fillColor = tint.cgColor
            circleLayer.strokeColor = UIColor.white.withAlphaComponent(0.7).cgColor
            circleLayer.lineWidth = 1
            layer.addSublayer(circleLayer)

            updatePaths()
        }

        private func updatePaths() {
            let centerX = bounds.midX
            let circleX = (bounds.width - Self.circleDiameter) / 2
            let visualStemHeight = max(12, stemHeight)

            if position == .start {
                let circleRect = CGRect(
                    x: circleX,
                    y: 0,
                    width: Self.circleDiameter,
                    height: Self.circleDiameter
                )
                circleLayer.path = UIBezierPath(ovalIn: circleRect).cgPath

                let stemPath = UIBezierPath()
                stemPath.move(to: CGPoint(x: centerX, y: circleRect.maxY - 0.5))
                stemPath.addLine(to: CGPoint(x: centerX, y: circleRect.maxY + visualStemHeight))
                stemLayer.path = stemPath.cgPath
            } else {
                let circleRect = CGRect(
                    x: circleX,
                    y: visualStemHeight,
                    width: Self.circleDiameter,
                    height: Self.circleDiameter
                )
                circleLayer.path = UIBezierPath(ovalIn: circleRect).cgPath

                let stemPath = UIBezierPath()
                stemPath.move(to: CGPoint(x: centerX, y: 0))
                stemPath.addLine(to: CGPoint(x: centerX, y: circleRect.minY + 0.5))
                stemLayer.path = stemPath.cgPath
            }

        }
    }

    class SelectionMagnifierView: UIView {

        enum Placement {
            case above
            case below
        }

        static let contentSize = CGSize(width: 152, height: 96)
        static let sourceSize = CGSize(width: 76, height: 48)
        static let verticalOffset: CGFloat = 104
        static let horizontalOffset: CGFloat = 60

        private static let cornerRadius: CGFloat = 26
        private static let magnification: CGFloat = 2
        private static let placementHysteresis: CGFloat = 12

        private let effectView: UIVisualEffectView
        private let materialEffect: UIVisualEffect
        private let usesSystemGlass: Bool
        private let contentClipView = UIView()
        private let reticleHaloView = UIView()
        private let reticleView = UIView()
        private let rimGradientLayer = CAGradientLayer()
        private let rimMaskLayer = CAShapeLayer()
        private var snapshotView: UIView?
        private weak var pendingSourceView: UIView?
        private var pendingSourcePoint: CGPoint?
        private var pendingCellSize: CGSize?
        private var snapshotRefreshScheduled = false
        private var snapshotRefreshGeneration = 0
        private var presentationAnimator: UIViewPropertyAnimator?
        private var dismissalAnimator: UIViewPropertyAnimator?
        private(set) var placement: Placement?

        override init(frame: CGRect) {
            let selectedEffect: UIVisualEffect
            let selectedSystemGlass: Bool

            #if os(visionOS)
            selectedEffect = UIBlurEffect(style: .systemChromeMaterial)
            selectedSystemGlass = false
            #else
            if #available(iOS 26.0, *) {
                let glass = UIGlassEffect(style: .clear)
                glass.isInteractive = false
                glass.tintColor = UIColor.systemBackground.withAlphaComponent(0.06)
                selectedEffect = glass
                selectedSystemGlass = true
            } else {
                selectedEffect = UIBlurEffect(style: .systemChromeMaterial)
                selectedSystemGlass = false
            }
            #endif

            materialEffect = selectedEffect
            usesSystemGlass = selectedSystemGlass
            effectView = UIVisualEffectView(effect: nil)

            super.init(frame: CGRect(origin: .zero, size: Self.contentSize))
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            backgroundColor = .clear
            layer.masksToBounds = false

            effectView.frame = bounds
            effectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            effectView.layer.cornerRadius = Self.cornerRadius
            effectView.layer.cornerCurve = .continuous
            if #available(iOS 26.0, *), usesSystemGlass {
                effectView.cornerConfiguration = .uniformCorners(radius: .fixed(Double(Self.cornerRadius)))
                // Let Liquid Glass draw its native elevation outside the lens.
                effectView.clipsToBounds = false
            } else {
                effectView.clipsToBounds = true
            }

            contentClipView.frame = bounds.insetBy(dx: 1, dy: 1)
            contentClipView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            contentClipView.layer.cornerRadius = Self.cornerRadius - 1
            contentClipView.layer.cornerCurve = .continuous
            contentClipView.clipsToBounds = true

            // Keep the magnified terminal above the material. Placing Liquid
            // Glass over the snapshot makes terminal glyphs noticeably soft on
            // iOS 26 because the effect processes everything behind it. Here it
            // remains visible as the lens rim and supplies native elevation,
            // while the snapshot itself stays pixel-sharp and unfiltered.
            addSubview(effectView)
            addSubview(contentClipView)

            rimGradientLayer.startPoint = CGPoint(x: 0.15, y: 0)
            rimGradientLayer.endPoint = CGPoint(x: 0.85, y: 1)
            rimGradientLayer.mask = rimMaskLayer
            layer.addSublayer(rimGradientLayer)

            reticleHaloView.backgroundColor = .clear
            reticleHaloView.layer.borderWidth = 3
            addSubview(reticleHaloView)

            reticleView.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.08)
            reticleView.layer.borderWidth = 1.25
            addSubview(reticleView)

            transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
            contentClipView.alpha = 0
            reticleHaloView.alpha = 0
            reticleView.alpha = 0

            registerForTraitChanges(UITraitCollection.systemTraitsAffectingColorAppearance) { (view: SelectionMagnifierView, _: UITraitCollection) in
                view.updateChromeColors()
            }
            updateChromeColors()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) not supported")
        }

        override func layoutSubviews() {
            super.layoutSubviews()

            let shapePath = UIBezierPath(
                roundedRect: bounds.insetBy(dx: 0.625, dy: 0.625),
                cornerRadius: Self.cornerRadius
            ).cgPath
            rimGradientLayer.frame = bounds
            rimGradientLayer.colors = [
                UIColor.white.withAlphaComponent(0.72).cgColor,
                UIColor.white.withAlphaComponent(0.12).cgColor,
                UIColor.black.withAlphaComponent(0.24).cgColor,
            ]
            rimGradientLayer.locations = [0, 0.48, 1]
            rimMaskLayer.path = shapePath
            rimMaskLayer.fillColor = UIColor.clear.cgColor
            rimMaskLayer.strokeColor = UIColor.black.cgColor
            rimMaskLayer.lineWidth = 1.25

            if !usesSystemGlass {
                layer.shadowPath = UIBezierPath(
                    roundedRect: bounds,
                    cornerRadius: Self.cornerRadius
                ).cgPath
            }
        }

        func resetPlacement() {
            placement = nil
        }

        func resolvedCenter(
            for windowPoint: CGPoint,
            horizontalOffset: CGFloat,
            inside usableFrame: CGRect
        ) -> CGPoint {
            let halfWidth = Self.contentSize.width / 2
            let halfHeight = Self.contentSize.height / 2
            let centerFrame = CGRect(
                x: usableFrame.minX + halfWidth,
                y: usableFrame.minY + halfHeight,
                width: max(0, usableFrame.width - Self.contentSize.width),
                height: max(0, usableFrame.height - Self.contentSize.height)
            )

            let aboveY = windowPoint.y - Self.verticalOffset
            let belowY = windowPoint.y + Self.verticalOffset
            let fitsAbove = aboveY >= centerFrame.minY
            let fitsBelow = belowY <= centerFrame.maxY
            let comfortablyFitsAbove = aboveY >= centerFrame.minY + Self.placementHysteresis

            switch placement {
            case .above where !fitsAbove && fitsBelow:
                placement = .below
            case .below where comfortablyFitsAbove:
                placement = .above
            case nil:
                if fitsAbove || !fitsBelow {
                    placement = .above
                } else {
                    placement = .below
                }
            default:
                break
            }

            let desiredY = placement == .below ? belowY : aboveY
            return CGPoint(
                x: min(max(windowPoint.x + horizontalOffset, centerFrame.minX), centerFrame.maxX),
                y: min(max(desiredY, centerFrame.minY), centerFrame.maxY)
            )
        }

        func requestSnapshot(
            from sourceView: UIView,
            around point: CGPoint,
            cellSize: CGSize?,
            immediately: Bool = false
        ) {
            pendingSourceView = sourceView
            pendingSourcePoint = point
            pendingCellSize = cellSize

            if immediately || snapshotView == nil {
                performSnapshotRefresh()
                return
            }

            guard !snapshotRefreshScheduled else { return }
            snapshotRefreshScheduled = true
            let generation = snapshotRefreshGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.snapshotRefreshGeneration == generation else { return }
                self.performSnapshotRefresh()
            }
        }

        func present(animated: Bool) {
            dismissalAnimator?.stopAnimation(true)
            dismissalAnimator = nil
            presentationAnimator?.stopAnimation(true)

            let changes = {
                self.transform = .identity
                self.effectView.effect = self.materialEffect
                self.contentClipView.alpha = 1
                self.reticleHaloView.alpha = 1
                self.reticleView.alpha = 1
            }

            guard animated, !UIAccessibility.isReduceMotionEnabled else {
                changes()
                return
            }

            let animator = UIViewPropertyAnimator(duration: 0.18, dampingRatio: 0.82, animations: changes)
            presentationAnimator = animator
            animator.addCompletion { [weak self, weak animator] _ in
                guard self?.presentationAnimator === animator else { return }
                self?.presentationAnimator = nil
            }
            animator.startAnimation()
        }

        func dismiss(animated: Bool, completion: @escaping () -> Void) {
            cancelPendingSnapshotRefresh()
            presentationAnimator?.stopAnimation(true)
            presentationAnimator = nil
            dismissalAnimator?.stopAnimation(true)

            let changes = {
                self.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
                self.effectView.effect = nil
                self.contentClipView.alpha = 0
                self.reticleHaloView.alpha = 0
                self.reticleView.alpha = 0
            }

            guard animated, !UIAccessibility.isReduceMotionEnabled else {
                changes()
                dismissalAnimator = nil
                completion()
                return
            }

            let animator = UIViewPropertyAnimator(duration: 0.12, curve: .easeIn, animations: changes)
            dismissalAnimator = animator
            animator.addCompletion { [weak self, weak animator] position in
                guard self?.dismissalAnimator === animator else { return }
                self?.dismissalAnimator = nil
                if position == .end {
                    completion()
                }
            }
            animator.startAnimation()
        }

        func cancelPendingSnapshotRefresh() {
            snapshotRefreshGeneration += 1
            snapshotRefreshScheduled = false
            pendingSourceView = nil
            pendingSourcePoint = nil
            pendingCellSize = nil
        }

        private func performSnapshotRefresh() {
            snapshotRefreshScheduled = false
            guard let sourceView = pendingSourceView, let point = pendingSourcePoint else { return }

            let capturedSourceRect = Self.sourceRect(around: point, inside: sourceView.bounds)

            guard capturedSourceRect.width > 4,
                  capturedSourceRect.height > 4,
                  let snapshot = sourceView.resizableSnapshotView(
                    from: capturedSourceRect,
                    afterScreenUpdates: false,
                    withCapInsets: .zero
                  ) else {
                return
            }

            let sampledPoint = CGPoint(
                x: min(max(point.x, capturedSourceRect.minX), capturedSourceRect.maxX),
                y: min(max(point.y, capturedSourceRect.minY), capturedSourceRect.maxY)
            )
            let reticleCenter = CGPoint(
                x: (sampledPoint.x - capturedSourceRect.minX) * Self.magnification,
                y: (sampledPoint.y - capturedSourceRect.minY) * Self.magnification
            )
            updateReticle(cellSize: pendingCellSize, center: reticleCenter)

            snapshot.frame = CGRect(
                x: -1,
                y: -1,
                width: capturedSourceRect.width * Self.magnification,
                height: capturedSourceRect.height * Self.magnification
            )

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let previousSnapshot = snapshotView
            contentClipView.addSubview(snapshot)
            snapshotView = snapshot
            previousSnapshot?.removeFromSuperview()
            CATransaction.commit()
        }

        private static func sourceRect(around point: CGPoint, inside bounds: CGRect) -> CGRect {
            let width = min(sourceSize.width, bounds.width)
            let height = min(sourceSize.height, bounds.height)
            guard width > 0, height > 0 else { return .null }

            let minX = bounds.minX
            let maxX = bounds.maxX - width
            let minY = bounds.minY
            let maxY = bounds.maxY - height
            return CGRect(
                x: min(max(point.x - width / 2, minX), maxX),
                y: min(max(point.y - height / 2, minY), maxY),
                width: width,
                height: height
            )
        }

        private func updateReticle(cellSize: CGSize?, center: CGPoint) {
            let projectedCell = CGSize(
                width: (cellSize?.width ?? 10) * Self.magnification,
                height: (cellSize?.height ?? 18) * Self.magnification
            )
            let reticleSize = CGSize(
                width: min(max(8, projectedCell.width), bounds.width - 24),
                height: min(max(12, projectedCell.height), bounds.height - 20)
            )
            let reticleFrame = CGRect(
                x: min(max(center.x - reticleSize.width / 2, 4), bounds.width - reticleSize.width - 4),
                y: min(max(center.y - reticleSize.height / 2, 4), bounds.height - reticleSize.height - 4),
                width: reticleSize.width,
                height: reticleSize.height
            ).integral

            reticleHaloView.frame = reticleFrame.insetBy(dx: -1, dy: -1)
            reticleHaloView.layer.cornerRadius = min(5, reticleHaloView.bounds.height / 4)
            reticleView.frame = reticleFrame
            reticleView.layer.cornerRadius = min(4, reticleView.bounds.height / 4)
        }

        private func updateChromeColors() {
            reticleHaloView.layer.borderColor = UIColor.black.withAlphaComponent(0.48).cgColor
            reticleView.layer.borderColor = UIColor.systemBlue.withAlphaComponent(0.92).cgColor

            if usesSystemGlass {
                layer.shadowOpacity = 0
            } else {
                layer.shadowColor = UIColor.black.cgColor
                layer.shadowOpacity = 0.24
                layer.shadowRadius = 14
                layer.shadowOffset = CGSize(width: 0, height: 8)
            }
        }
    }
}

#endif
