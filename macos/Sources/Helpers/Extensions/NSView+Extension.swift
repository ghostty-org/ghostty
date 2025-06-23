import AppKit
import SwiftUI

extension NSView {
    /// Returns true if this view is currently in the responder chain
    var isInResponderChain: Bool {
        var responder = window?.firstResponder
        while let currentResponder = responder {
            if currentResponder === self {
                return true
            }
            responder = currentResponder.nextResponder
        }

        return false
    }
}

// MARK: Screenshot

extension NSView {
    /// Take a screenshot of just this view.
    func screenshot() -> NSImage? {
        guard let bitmapRep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: bitmapRep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(bitmapRep)
        return image
    }

    func screenshot() -> Image? {
        guard let nsImage: NSImage = self.screenshot() else { return nil }
        return Image(nsImage: nsImage)
    }
}

// MARK: View Traversal and Search

extension NSView {
    /// Returns the absolute root view by walking up the superview chain.
    var rootView: NSView {
        var root: NSView = self
        while let superview = root.superview {
            root = superview
        }
        return root
    }

    /// Checks if a view contains another view in its hierarchy.
    func contains(_ view: NSView) -> Bool {
        if self == view {
            return true
        }

        for subview in subviews {
            if subview.contains(view) {
                return true
            }
        }

        return false
    }

    /// Checks if the view contains the given class in its hierarchy.
    func contains(className name: String) -> Bool {
        if String(describing: type(of: self)) == name {
            return true
        }

        for subview in subviews {
            if subview.contains(className: name) {
                return true
            }
        }

        return false
    }

    /// Finds the superview with the given class name.
    func firstSuperview(withClassName name: String) -> NSView? {
        guard let superview else { return nil }
        if String(describing: type(of: superview)) == name {
            return superview
        }

        return superview.firstSuperview(withClassName: name)
    }

    /// Recursively finds and returns the first descendant view that has the given class name.
    func firstDescendant(withClassName name: String) -> NSView? {
        for subview in subviews {
            if String(describing: type(of: subview)) == name {
                return subview
            } else if let found = subview.firstDescendant(withClassName: name) {
                return found
            }
        }

        return nil
    }

    /// Recursively finds and returns descendant views that have the given class name.
    func descendants(withClassName name: String) -> [NSView] {
        var result = [NSView]()

        for subview in subviews {
            if String(describing: type(of: subview)) == name {
                result.append(subview)
            }

            result += subview.descendants(withClassName: name)
        }

        return result
    }

	/// Recursively finds and returns the first descendant view that has the given identifier.
	func firstDescendant(withID id: String) -> NSView? {
		for subview in subviews {
			if subview.identifier == NSUserInterfaceItemIdentifier(id) {
				return subview
			} else if let found = subview.firstDescendant(withID: id) {
				return found
			}
		}

		return nil
	}

	/// Finds and returns the first view with the given class name starting from the absolute root of the view hierarchy.
	/// This includes private views like title bar views.
	func firstViewFromRoot(withClassName name: String) -> NSView? {
		let root = rootView
		
		// Check if the root view itself matches
		if String(describing: type(of: root)) == name {
			return root
		}
		
		// Otherwise search descendants
		return root.firstDescendant(withClassName: name)
	}
}

// MARK: Debug

extension NSView {
	/// Prints the view hierarchy from the root in a tree-like ASCII format.
    ///
    /// I need this because the "Capture View Hierarchy" was broken under some scenarios in
    /// Xcode 26 (FB17912569). But, I kept it around because it might be useful to print out
    /// the view hierarchy without halting the program.
	func printViewHierarchy() {
		let root = rootView
		print("View Hierarchy from Root:")
		print(root.viewHierarchyDescription())
	}
	
	/// Returns a string representation of the view hierarchy in a tree-like format.
	func viewHierarchyDescription(indent: String = "", isLast: Bool = true) -> String {
		var result = ""
		
		// Add the tree branch characters
		result += indent
		if !indent.isEmpty {
			result += isLast ? "└── " : "├── "
		}
		
		// Add the class name and optional identifier
		let className = String(describing: type(of: self))
		result += className
		
		// Add identifier if present
		if let identifier = self.identifier {
			result += " (id: \(identifier.rawValue))"
		}
		
		// Add frame info
		result += " [frame: \(frame)]"
		
		// Add visual properties
		var properties: [String] = []
		
		// Hidden status
		if isHidden {
			properties.append("hidden")
		}
		
		// Opaque status
		properties.append(isOpaque ? "opaque" : "transparent")
		
		// Layer backing
		if wantsLayer {
			properties.append("layer-backed")
			if let bgColor = layer?.backgroundColor {
				let color = NSColor(cgColor: bgColor)
				if let rgb = color?.usingColorSpace(.deviceRGB) {
					properties.append(String(format: "bg:rgba(%.0f,%.0f,%.0f,%.2f)", 
						rgb.redComponent * 255, 
						rgb.greenComponent * 255, 
						rgb.blueComponent * 255, 
						rgb.alphaComponent))
				} else {
					properties.append("bg:\(bgColor)")
				}
			}
		}
		
		result += " [\(properties.joined(separator: ", "))]"
		result += "\n"
		
		// Process subviews
		for (index, subview) in subviews.enumerated() {
			let isLastSubview = index == subviews.count - 1
			let newIndent = indent + (isLast ? "    " : "│   ")
			result += subview.viewHierarchyDescription(indent: newIndent, isLast: isLastSubview)
		}
		
		return result
	}
}
