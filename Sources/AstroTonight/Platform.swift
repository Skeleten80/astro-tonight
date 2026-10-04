#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif
import Foundation
import SwiftUI

// MARK: - Platform shims (macOS + iOS/iPadOS)
//
// One universal codebase: the AppKit/UIKit seams live here so the views
// stay clean. Views should use these helpers and only reach for `#if os()`
// directly for view modifiers with no iOS equivalent (e.g. `.onHover`).

#if os(macOS)
/// Cross-platform image type: NSImage on macOS, UIImage on iOS.
typealias PlatformImage = NSImage
#elseif os(iOS)
/// Cross-platform image type: NSImage on macOS, UIImage on iOS.
typealias PlatformImage = UIImage
#endif

/// Decode image bytes cross-platform.
func platformImage(from data: Data) -> PlatformImage? {
    #if os(macOS)
    return NSImage(data: data)
    #elseif os(iOS)
    return UIImage(data: data)
    #endif
}

extension Image {
    /// Cross-platform image view: `Image(nsImage:)` on macOS,
    /// `Image(uiImage:)` on iOS.
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #elseif os(iOS)
        self.init(uiImage: platformImage)
        #endif
    }
}

/// Copy text to the system clipboard: NSPasteboard on macOS,
/// UIPasteboard on iOS.
enum PlatformPasteboard {
    static func copy(_ text: String) {
        #if os(macOS)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = text
        #endif
    }
}

/// System-settings links and the few user-facing strings that name the
/// platform ("this Mac" vs "this device").
enum PlatformSystem {
    /// Open the location-privacy settings: the System Settings pane on
    /// macOS, the app's own Settings page on iOS (the standard iOS
    /// pattern — iOS has no deep link to the system Location Services
    /// page).
    static func openLocationSettings() {
        #if os(macOS)
        if let url = URL(string: "x-apple.systempreferences:" +
            "com.apple.preference.security?Privacy_LocationServices")
        {
            NSWorkspace.shared.open(url)
        }
        #elseif os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
    }

    static var locationServicesOffMessage: String {
        #if os(macOS)
        return "Location Services are turned off on this Mac " +
            "(System Settings → Privacy & Security → Location Services)."
        #elseif os(iOS)
        return "Location Services are turned off on this device " +
            "(Settings → Privacy & Security → Location Services)."
        #endif
    }

    static var locationDeniedHint: String {
        #if os(macOS)
        return "Location access denied — set the site manually, " +
            "or allow it in System Settings."
        #elseif os(iOS)
        return "Location access denied — set the site manually, " +
            "or allow it in Settings."
        #endif
    }

    static var useLocationHelp: String {
        #if os(macOS)
        return "Set the site from this Mac's location services"
        #elseif os(iOS)
        return "Set the site from this device's location services"
        #endif
    }
}
