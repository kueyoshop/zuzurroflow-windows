import AppKit

/// App LSUIElement (sin barra de menús): los atajos de edición
/// (Cmd+A/C/V/X/Z) NO llegan a los campos de texto porque se enrutan por el
/// menú principal, que no existe. Instalamos uno mínimo con el menú Edición
/// estándar — sus selectores viajan por el responder chain hasta el NSTextView
/// del Scratchpad y del Dashboard, así que copiar/pegar/seleccionar-todo/
/// deshacer funcionan aunque el menú no se vea.
enum EditMenu {
    @MainActor
    static func install() {
        guard NSApp.mainMenu == nil else { return }

        let mainMenu = NSMenu()

        // Menú de aplicación (vacío salvo Salir — necesario para el layout).
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Salir de Dictator", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        // Menú Edición.
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edición")
        editMenu.addItem(withTitle: "Deshacer", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Rehacer", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cortar", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copiar", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Pegar", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Seleccionar todo", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }
}
