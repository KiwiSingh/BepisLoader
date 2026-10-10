import AppKit

final class AssetModProfileWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private var profile: AssetModProfile
    private let packages: [String: AssetModPackage]
    private let adapter: AssetModAdapter
    private let apply: (AssetModProfile, AssetProfileMerge, AssetModProfileWindowController) -> Void
    private let table = NSTableView()
    private let summary = NSTextField(wrappingLabelWithString: "")
    private var actionButtons: [NSButton] = []
    private let applyButton = NSButton(title: "Apply changes", target: nil, action: nil)
    init(profile: AssetModProfile, packages: [String: AssetModPackage], adapter: AssetModAdapter,
         apply: @escaping (AssetModProfile, AssetProfileMerge, AssetModProfileWindowController) -> Void) {
        self.profile = profile; self.packages = packages; self.adapter = adapter; self.apply = apply
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 540),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.contentMinSize = NSSize(width: 620, height: 480)
        window.title = "Manage asset mods"; window.isReleasedWhenClosed = false
        super.init(window: window)
        table.dataSource = self; table.delegate = self
        for (id, title, width) in [("enabled", "Enabled", 75.0), ("name", "Mod", 400.0), ("assets", "Assets", 90.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width; table.addTableColumn(column)
        }
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        let up = NSButton(title: "Move up", target: self, action: #selector(moveModUp))
        let down = NSButton(title: "Move down", target: self, action: #selector(moveModDown))
        let remove = NSButton(title: "Remove from profile", target: self, action: #selector(removeMod))
        applyButton.target = self; applyButton.action = #selector(applyChanges)
        actionButtons = [up, down, remove, applyButton]
        let actions = NSStackView(views: [up, down, remove, applyButton]); actions.spacing = 10
        let help = NSTextField(wrappingLabelWithString: "Enable the mods you want. All enabled mods are combined. Lower mods win for the same replacement file; MBE CSV edits merge by cell, with lower mods winning competing edits. Close the game before applying changes; Steam can stay open. Stored packages are retained when removed.")
        let stack = NSStackView(views: [help, scroll, summary, actions]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -16), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 16), stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -16), help.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200), summary.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        refresh(); window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func numberOfRows(in tableView: NSTableView) -> Int { profile.mods.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let mod = profile.mods[row]
        if tableColumn?.identifier.rawValue == "enabled" {
            let check = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggle)); check.tag = row; check.state = mod.enabled ? .on : .off; return check
        }
        let name = profile.mods.filter { $0.name == mod.name }.count > 1 ? "\(mod.name) (\(mod.id.prefix(8)))" : mod.name
        return NSTextField(labelWithString: tableColumn?.identifier.rawValue == "assets" ? String(packages[mod.id]?.files.count ?? 0) : name)
    }
    @objc private func toggle(_ button: NSButton) { guard applyButton.isEnabled else { refresh(); return }; profile.mods[button.tag].enabled = button.state == .on; refresh() }
    @objc private func moveModUp() { move(-1) }
    @objc private func moveModDown() { move(1) }
    private func move(_ direction: Int) {
        guard applyButton.isEnabled else { return }
        let row = table.selectedRow, next = row + direction
        guard profile.mods.indices.contains(row), profile.mods.indices.contains(next) else { return }
        profile.mods.swapAt(row, next); refresh(); table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
    }
    @objc private func removeMod() { guard applyButton.isEnabled else { return }; let row = table.selectedRow; guard profile.mods.indices.contains(row) else { return }; profile.mods.remove(at: row); refresh() }
    private func refresh() {
        table.reloadData()
        do { let merge = try AssetModProfiles.merge(profile, packages: packages, adapter: adapter)
            summary.stringValue = "\(profile.mods.filter(\.enabled).count) enabled mods · \(merge.package.files.count) replacement inputs · \(merge.conflicts.count) conflicts. Priority only resolves overlapping replacements."
        } catch { summary.stringValue = error.localizedDescription }
    }
    @objc private func applyChanges() {
        do {
            let merge = try AssetModProfiles.merge(profile, packages: packages, adapter: adapter)
            let review = NSAlert(); review.messageText = "Apply this asset profile?"
            let conflicts = merge.conflicts.sorted(by: { $0.key < $1.key }).map {
                $0.key.lowercased().hasSuffix(".csv")
                    ? "\($0.key): cell edits combine from \($0.value.joined(separator: ", ")); later mods win competing cell edits"
                    : "\($0.key): \($0.value.last!) wins over \($0.value.dropLast().joined(separator: ", "))"
            }.joined(separator: "\n")
            review.informativeText = "\(profile.mods.filter(\.enabled).count) enabled mods, \(merge.package.files.count) replacement inputs. Your stable Steam launch setting stays the same.\n\n" + (conflicts.isEmpty ? "No asset conflicts." : "Conflict choices from your load order are listed below. Change the order to choose different winners.")
            if !conflicts.isEmpty {
                let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 540, height: 180)); text.isEditable = false; text.string = conflicts
                let scroll = NSScrollView(frame: text.frame); scroll.documentView = text; scroll.hasVerticalScroller = true
                text.isVerticallyResizable = true; text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
                review.accessoryView = scroll
            }
            review.addButton(withTitle: "Apply"); review.addButton(withTitle: "Review order")
            guard review.runModal() == .alertFirstButtonReturn else { return }
            table.isEnabled = false; actionButtons.forEach { $0.isEnabled = false }; apply(profile, merge, self)
        } catch { let alert = NSAlert(); alert.messageText = "Cannot apply asset profile"; alert.informativeText = error.localizedDescription; alert.runModal() }
    }
    func allowRetry() { table.isEnabled = true; actionButtons.forEach { $0.isEnabled = true } }
}
