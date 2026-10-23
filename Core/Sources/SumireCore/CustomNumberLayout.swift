import Foundation

/// Built-in number proxy for custom input modes, pinned to Android df1f383
/// KeyboardDefaultLayouts.createNumberLayout. The right column contains no mode-return key.
public enum CustomNumberLayout {
    public static func layout() throws -> ImportedCustomLayout {
        var editor = CustomLayoutEditor(name: "数字", rows: 4, columns: 4)
        let cells = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], [",", "0", "."]]
        for (row, values) in cells.enumerated() {
            for (column, value) in values.enumerated() {
                let id = "number-" + (value == "," ? "comma" : value == "." ? "dot" : value)
                editor.putKey(id: id, label: value, action: "Text:" + value, special: false,
                              row: row * 2, column: column * 2, height: 2, width: 2)
                try editor.setKeyType(id: id, type: "STANDARD_FLICK")
                var mappings = [mapping("TAP", value)]
                if value == "," || value == "." {
                    let outputs = value == "," ? ["+", "-", "*", "/"] : ["(", "%", ")", "="]
                    mappings += zip(["UP_LEFT_FAR", "UP", "UP_RIGHT_FAR", "DOWN"], outputs).map { mapping($0.0, $0.1) }
                }
                try editor.setGestureMappings(id: id, field: "flicks", mappings: mappings)
            }
        }
        let specials = [("globe", "🌐", "SwitchToNextIme", "language_24dp"),
                        ("space", "空白", "Space", "baseline_space_bar_24"),
                        ("delete", "⌫", "Delete", "backspace_24px"),
                        ("enter", "改行", "NewLine", "baseline_keyboard_return_24")]
        for (row, item) in specials.enumerated() {
            editor.putKey(id: "number-" + item.0, label: item.1, action: item.2, special: true,
                          row: row * 2, column: 6, height: 2, width: 2)
        }
        // Android's no-argument DeleteKeyFlickSettings enables only left deletion.
        try editor.setKeyType(id: "number-delete", type: "CROSS_FLICK")
        try editor.setGestureMappings(id: "number-delete", field: "flicks", mappings: [
            mapping("TAP", "", action: "Delete"), mapping("UP_LEFT", "", action: "DeleteUntilSymbol")
        ])
        guard case .object(var source) = editor.source,
              case .object(var metadata) = source["layout"],
              case .array(var keys) = source["keysWithFlicks"] else {
            throw PersonalDataError("数字配列の定義が不正です")
        }
        metadata["stableId"] = .string("sumire-built-in-custom-number")
        source["layout"] = .object(metadata)
        for index in keys.indices {
            guard case .object(var item) = keys[index], case .object(var key) = item["key"],
                  let id = key["keyIdentifier"]?.string,
                  let special = specials.first(where: { "number-" + $0.0 == id }) else { continue }
            // Resource names are retained without Android's process-local numeric IDs.
            key["drawableResourceName"] = .string(special.3)
            item["key"] = .object(key); keys[index] = .object(item)
        }
        source["keysWithFlicks"] = .array(keys)
        let preview = try CustomLayoutImportPreview.parse(JSONEncoder().encode(LayoutJSON.object(source)))
        guard let layout = preview.layouts.first, preview.errors.isEmpty else {
            throw PersonalDataError("数字配列を読み込めません")
        }
        return layout
    }
    private static func mapping(_ direction: String, _ value: String, action: String = "INPUT_TEXT") -> LayoutJSON {
        .object(["stateIndex": .integer(0), "flickDirection": .string(direction),
                 "actionType": .string(action), "actionValue": .string(value)])
    }
}
