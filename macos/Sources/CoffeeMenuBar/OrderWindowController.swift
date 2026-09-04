import AppKit

/// "New Order…" window: a drink popup grouped by hot/cold, a shots popup, and
/// one popup per option collection. Rows show/hide based on the selected
/// drink's optionGroups; requiredOptions lose their "None" entry; the drink's
/// defaultOptions pre-select values.
@MainActor
final class OrderWindowController: NSWindowController {
    private let client: FirestoreClient
    private let orderService: OrderService

    /// Called after an order is successfully placed.
    var onPlaced: ((LastOrder) -> Void)?

    private var catalog: Catalog?
    private var loading = false
    private var placing = false
    private var shopState: ShopState = .unknown

    private let drinkPopup = NSPopUpButton()
    private let shotsPopup = NSPopUpButton()
    private var optionPopups: [String: NSPopUpButton] = [:]
    private var optionLabels: [String: NSTextField] = [:]
    private var optionRowIndex: [String: Int] = [:]
    private let shotsRowIndex = 1
    private var grid: NSGridView!
    private var stack: NSStackView!
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let orderButton = NSButton(title: "Place Order", target: nil, action: nil)
    private let spinner = NSProgressIndicator()

    init(client: FirestoreClient, orderService: OrderService) {
        self.client = client
        self.orderService = orderService
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Order Coffee"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func show() {
        window?.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        if catalog == nil && !loading {
            loadCatalog()
        }
    }

    func shopStateChanged(_ state: ShopState) {
        shopState = state
        if !placing {
            updateStatusLine()
            validate()
        }
    }

    // MARK: - UI construction

    private func buildUI() {
        drinkPopup.target = self
        drinkPopup.action = #selector(drinkChanged)
        (drinkPopup.menu ?? NSMenu()).autoenablesItems = false

        shotsPopup.target = self
        shotsPopup.action = #selector(selectionChanged)
        for (title, tag) in [("Single", 1), ("Double", 2), ("Triple", 3)] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.tag = tag
            shotsPopup.menu?.addItem(item)
        }

        var rows: [[NSView]] = [
            [fieldLabel("Drink"), drinkPopup],
            [fieldLabel("Shots"), shotsPopup],
        ]
        for (coll, title) in optionCollections {
            let popup = NSPopUpButton()
            popup.target = self
            popup.action = #selector(selectionChanged)
            optionPopups[coll] = popup
            let label = fieldLabel(title)
            optionLabels[coll] = label
            optionRowIndex[coll] = rows.count
            rows.append([label, popup])
        }

        grid = NSGridView(views: rows)
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        // One fixed width shared by every popup so no dropdown (e.g. toppings,
        // with its long option names) grows wider than the rest.
        for popup in [drinkPopup, shotsPopup] + Array(optionPopups.values) {
            popup.widthAnchor.constraint(equalToConstant: 250).isActive = true
        }

        statusLabel.textColor = .secondaryLabelColor

        orderButton.target = self
        orderButton.action = #selector(placeClicked)
        orderButton.bezelStyle = .rounded
        orderButton.keyEquivalent = "\r"
        orderButton.isEnabled = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let flexibleSpace = NSView()
        flexibleSpace.setContentHuggingPriority(.init(1), for: .horizontal)
        let bottomRow = NSStackView(views: [spinner, flexibleSpace, orderButton])
        bottomRow.orientation = .horizontal
        bottomRow.distribution = .fill

        stack = NSStackView(views: [grid, statusLabel, bottomRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        // The form (grid) dictates the window width; the status line and the
        // bottom row stay within it so both margins come out equal.
        bottomRow.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true

        window?.contentView = stack
        setControls(enabled: false)
        statusLabel.stringValue = "Loading menu…"
        resize()
    }

    private func fieldLabel(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    private func resize() {
        guard let window else { return }
        grid.layoutSubtreeIfNeeded()
        statusLabel.preferredMaxLayoutWidth = grid.fittingSize.width
        stack.layoutSubtreeIfNeeded()
        window.setContentSize(stack.fittingSize)
    }

    private func setControls(enabled: Bool) {
        drinkPopup.isEnabled = enabled
        shotsPopup.isEnabled = enabled
        for popup in optionPopups.values { popup.isEnabled = enabled }
    }

    // MARK: - Catalog

    private func loadCatalog() {
        loading = true
        spinner.startAnimation(nil)
        Task { @MainActor in
            do {
                let catalog = try await fetchCatalog()
                self.catalog = catalog
                populateDrinks()
                setControls(enabled: true)
                updateStatusLine()
            } catch {
                statusLabel.stringValue = "Failed to load menu: \(error.localizedDescription)"
            }
            loading = false
            spinner.stopAnimation(nil)
        }
    }

    private func fetchCatalog() async throws -> Catalog {
        let client = self.client
        async let drinkDocsAsync = client.listCollection(
            "drinks",
            fieldMask: ["name", "category", "optionGroups", "requiredOptions", "defaultOptions"]
        )
        async let categoryDocsAsync = client.listCollection("drinkCategories")

        var options: [String: [OptionItem]] = [:]
        try await withThrowingTaskGroup(of: (String, [OptionItem]).self) { group in
            for (coll, _) in optionCollections {
                group.addTask {
                    let docs = try await client.listCollection(coll)
                    let items = docs
                        .compactMap { doc -> OptionItem? in
                            guard let name = FS.string(doc.fields, "name") else { return nil }
                            return OptionItem(id: doc.id, name: name)
                        }
                        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    return (coll, items)
                }
            }
            for try await (coll, items) in group {
                options[coll] = items
            }
        }

        let categories = Dictionary(uniqueKeysWithValues: try await categoryDocsAsync.map { doc in
            (doc.id, DrinkCategory(
                id: doc.id,
                name: FS.string(doc.fields, "name") ?? "",
                order: Int(FS.int(doc.fields, "order") ?? 999)
            ))
        })

        // Same filtering as the CLI's `drinks` command: only hot/cold categories.
        var drinks: [Drink] = []
        for doc in try await drinkDocsAsync {
            guard let name = FS.string(doc.fields, "name") else { continue }
            let drinkCategories = FS.refArray(doc.fields, "category")
                .compactMap { categories[$0] }
                .filter { $0.name == "hot" || $0.name == "cold" }
            guard let primary = drinkCategories.min(by: { $0.order < $1.order }) else { continue }

            var defaults: [String: String] = [:]
            for (coll, value) in FS.mapFields(doc.fields, "defaultOptions") {
                if let ref = (value as? [String: Any])?["referenceValue"] as? String {
                    defaults[coll] = FS.lastPathComponent(ref)
                }
            }
            drinks.append(Drink(
                id: doc.id,
                name: name,
                categoryID: primary.id,
                optionGroups: Set(FS.mapFields(doc.fields, "optionGroups").keys),
                requiredOptions: Set(FS.stringArray(doc.fields, "requiredOptions")),
                defaultOptionIDs: defaults
            ))
        }
        drinks.sort { a, b in
            let ca = categories[a.categoryID]!
            let cb = categories[b.categoryID]!
            if ca.order != cb.order { return ca.order < cb.order }
            if ca.name != cb.name { return ca.name < cb.name }
            return a.name < b.name
        }

        return Catalog(drinks: drinks, categories: categories, options: options)
    }

    private func populateDrinks() {
        guard let catalog, let menu = drinkPopup.menu else { return }
        drinkPopup.removeAllItems()
        menu.autoenablesItems = false

        var currentCategory: String?
        for drink in catalog.drinks {
            guard let category = catalog.categories[drink.categoryID] else { continue }
            if category.id != currentCategory {
                if currentCategory != nil { menu.addItem(.separator()) }
                let header = NSMenuItem(title: category.name.capitalized, action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
                currentCategory = category.id
            }
            let item = NSMenuItem(title: drink.name, action: nil, keyEquivalent: "")
            item.representedObject = drink
            item.indentationLevel = 1
            menu.addItem(item)
        }

        if let first = menu.items.firstIndex(where: { $0.representedObject != nil }) {
            drinkPopup.selectItem(at: first)
        }
        drinkChanged()
    }

    private var selectedDrink: Drink? {
        drinkPopup.selectedItem?.representedObject as? Drink
    }

    private func selectedOption(_ coll: String) -> OptionItem? {
        optionPopups[coll]?.selectedItem?.representedObject as? OptionItem
    }

    private var shots: Int {
        max(shotsPopup.selectedTag(), 1)
    }

    // MARK: - Actions

    @objc private func drinkChanged() {
        guard let catalog, let drink = selectedDrink else { return }

        grid.row(at: shotsRowIndex).isHidden = !drink.optionGroups.contains("beans")

        for (coll, title) in optionCollections {
            guard let row = optionRowIndex[coll], let popup = optionPopups[coll] else { continue }
            let items = catalog.options[coll] ?? []
            let applicable = drink.optionGroups.contains(coll) && !items.isEmpty
            grid.row(at: row).isHidden = !applicable
            guard applicable else { continue }

            let required = drink.requiredOptions.contains(coll)
            optionLabels[coll]?.stringValue = required ? "\(title) *" : title

            popup.removeAllItems()
            let menu = popup.menu!
            menu.autoenablesItems = false
            if !required {
                menu.addItem(NSMenuItem(title: "None", action: nil, keyEquivalent: ""))
            }
            for option in items {
                let item = NSMenuItem(title: option.name, action: nil, keyEquivalent: "")
                item.representedObject = option
                menu.addItem(item)
            }

            var index: Int?
            if let defaultID = drink.defaultOptionIDs[coll] {
                index = menu.items.firstIndex { ($0.representedObject as? OptionItem)?.id == defaultID }
            }
            if index == nil && coll == "beans" {
                // Same default as the CLI's order command (Medium Roast).
                index = menu.items.firstIndex { ($0.representedObject as? OptionItem)?.name == "Medium Roast" }
            }
            if index == nil && required {
                index = menu.items.firstIndex { $0.representedObject != nil }
            }
            popup.selectItem(at: index ?? 0)
        }

        resize()
        updateStatusLine()
        validate()
    }

    @objc private func selectionChanged() {
        validate()
    }

    private func validate() {
        guard !placing else { orderButton.isEnabled = false; return }
        guard let drink = selectedDrink else { orderButton.isEnabled = false; return }
        var complete = true
        for coll in drink.requiredOptions {
            guard let row = optionRowIndex[coll], !grid.row(at: row).isHidden else { continue }
            if selectedOption(coll) == nil { complete = false }
        }
        orderButton.isEnabled = complete && catalog != nil
    }

    private func updateStatusLine() {
        guard !placing else { return }
        switch shopState {
        case .closed:
            statusLabel.stringValue = catalog == nil ? "Loading menu…" : "The shop is closed — orders will be waiting when it opens."
        case .unknown, .open:
            statusLabel.stringValue = catalog == nil ? "Loading menu…" : ""
        }
    }

    @objc private func placeClicked() {
        guard let drink = selectedDrink, !placing else { return }

        var selected: [SelectedOption] = []
        for (coll, _) in optionCollections {
            guard let row = optionRowIndex[coll], !grid.row(at: row).isHidden,
                  let option = selectedOption(coll) else { continue }
            let count = coll == "beans" ? shots : 1
            selected.append(SelectedOption(collection: coll, id: option.id, name: option.name, count: count))
        }

        placing = true
        setControls(enabled: false)
        orderButton.isEnabled = false
        spinner.startAnimation(nil)
        statusLabel.stringValue = "Placing order…"
        let shots = self.shots

        Task { @MainActor in
            do {
                let (position, last) = try await orderService.place(
                    drinkID: drink.id,
                    drinkName: drink.name,
                    options: selected,
                    shots: shots
                )
                onPlaced?(last)
                if let position {
                    statusLabel.stringValue = "✓ Order placed — you're number \(position) in the queue."
                } else {
                    statusLabel.stringValue = "✓ Order placed."
                }
                spinner.stopAnimation(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self else { return }
                    self.placing = false
                    self.setControls(enabled: true)
                    self.updateStatusLine()
                    self.validate()
                    self.close()
                }
            } catch {
                placing = false
                spinner.stopAnimation(nil)
                setControls(enabled: true)
                statusLabel.stringValue = "Order failed: \(error.localizedDescription)"
                validate()
            }
        }
    }
}
