#if DEBUG
import CarPlay
import Foundation
import UIKit

/// DEBUG-only textual dump of the live CarPlay template tree.
///
/// Use from the debugger / diagnostics when CarPlay Simulator isn't available
/// on a headless Mac: call `CarPlaySceneDelegate.dumpTemplateTree(...)`.
enum CarPlayTemplateDump {
    static func dump(
        root: CPTemplate?,
        limits: CarPlayListPolicy.Limits,
        nowPlaying: CPNowPlayingTemplate = .shared
    ) -> String {
        var lines: [String] = []
        lines.append("=== CarPlay template tree ===")
        lines.append("limits: sections≤\(limits.maxSections) items≤\(limits.maxItems) listsLimited=\(limits.listsLimited)")
        lines.append("CPListTemplate.maximumSectionCount=\(CPListTemplate.maximumSectionCount)")
        lines.append("CPListTemplate.maximumItemCount=\(CPListTemplate.maximumItemCount)")
        lines.append("")

        if let root {
            dumpTemplate(root, indent: 0, into: &lines, limits: limits)
        } else {
            lines.append("(no root template)")
        }

        lines.append("")
        lines.append("--- Now Playing ---")
        lines.append("upNext=\(nowPlaying.isUpNextButtonEnabled) title=\(nowPlaying.upNextTitle ?? "nil")")
        lines.append("albumArtist=\(nowPlaying.isAlbumArtistButtonEnabled)")
        let buttons = nowPlaying.nowPlayingButtons
        lines.append("buttons(\(buttons.count)/5):")
        for (i, button) in buttons.enumerated() {
            lines.append("  [\(i)] \(describeButton(button)) selected=\(button.isSelected)")
        }
        return lines.joined(separator: "\n")
    }

    static func dumpSpec(_ spec: CarPlayListPolicy.TemplateSpec, limits: CarPlayListPolicy.Limits) -> String {
        CarPlayListPolicy.dumpSpec(spec, limits: limits)
    }

    // MARK: - Live templates

    private static func dumpTemplate(
        _ template: CPTemplate,
        indent: Int,
        into lines: inout [String],
        limits: CarPlayListPolicy.Limits
    ) {
        let pad = String(repeating: "  ", count: indent)
        if let tabs = template as? CPTabBarTemplate {
            lines.append("\(pad)CPTabBarTemplate tabs=\(tabs.templates.count)")
            for (i, child) in tabs.templates.enumerated() {
                lines.append("\(pad)  tab[\(i)]")
                dumpTemplate(child, indent: indent + 2, into: &lines, limits: limits)
            }
            return
        }
        if let list = template as? CPListTemplate {
            let sections = list.sections
            let itemCount = sections.reduce(0) { $0 + $1.items.count }
            let tab = list.tabTitle.map { " tabTitle=\"\($0)\"" } ?? ""
            lines.append("\(pad)CPListTemplate title=\"\(list.title ?? "")\"\(tab) sections=\(sections.count)/\(limits.maxSections) items=\(itemCount)/\(limits.maxItems) overLimit=\(itemCount > limits.maxItems || sections.count > limits.maxSections)")
            if let img = list.tabImage {
                lines.append("\(pad)  tabImage=\(img.cgImage != nil ? "y" : "n")")
            }
            for (si, section) in sections.enumerated() {
                lines.append("\(pad)  section[\(si)] header=\(section.header ?? "nil") items=\(section.items.count)")
                for (ii, raw) in section.items.enumerated() {
                    lines.append("\(pad)    [\(ii)] \(describeItem(raw))")
                }
            }
            return
        }
        if template is CPSearchTemplate {
            lines.append("\(pad)CPSearchTemplate")
            return
        }
        if template is CPNowPlayingTemplate {
            lines.append("\(pad)CPNowPlayingTemplate (shared)")
            return
        }
        if let grid = template as? CPGridTemplate {
            lines.append("\(pad)CPGridTemplate title=\"\(grid.title ?? "")\" buttons=\(grid.gridButtons.count)")
            return
        }
        lines.append("\(pad)\(String(describing: type(of: template)))")
    }

    private static func describeItem(_ item: CPListTemplateItem) -> String {
        if let row = item as? CPListImageRowItem {
            let imgs = row.gridImages
            let present = imgs.filter { $0.size.width > 1 }.count
            return "ImageRow \"\(row.text ?? "")\" tiles=\(imgs.count) withBitmap=\(present)"
        }
        if let listItem = item as? CPListItem {
            var s = "Item \"\(listItem.text ?? "")\""
            if let d = listItem.detailText { s += " — \"\(d)\"" }
            let hasImg = listItem.image != nil && (listItem.image?.size.width ?? 0) > 0
            s += " img=\(hasImg ? "y" : "n")"
            switch listItem.accessoryType {
            case .disclosureIndicator: s += " accessory=disclosure"
            case .cloud: s += " accessory=cloud"
            default: break
            }
            return s
        }
        return String(describing: type(of: item))
    }

    private static func describeButton(_ button: CPNowPlayingButton) -> String {
        if button is CPNowPlayingShuffleButton { return "Shuffle" }
        if button is CPNowPlayingRepeatButton { return "Repeat" }
        if button is CPNowPlayingImageButton { return "ImageButton" }
        if button is CPNowPlayingPlaybackRateButton { return "Rate" }
        if button is CPNowPlayingAddToLibraryButton { return "AddToLibrary" }
        if button is CPNowPlayingMoreButton { return "More" }
        return String(describing: type(of: button))
    }
}
#endif
