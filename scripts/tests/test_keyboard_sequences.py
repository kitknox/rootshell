#!/usr/bin/env python3
"""Run the production sequence dispatcher and byte encoder without UIKit."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
keyboard = root / "rootshell/UI/Keyboard"
buttons = (keyboard / "KeyboardButton.swift").read_text()
models = (keyboard / "KeyboardToolbarCustomization.swift").read_text()
source = "import Foundation\nstruct KeyModifiers {}\n"
source += buttons[buttons.index("protocol KeyboardButtonDelegate"):buttons.index("// MARK: - Key Modifiers")]
source += models[models.index("enum SequenceStep:"):models.index("extension CustomKey {")]
source += models[models.index("extension SequenceStep.KeyCombo {"):]
source += r'''
final class Recorder: KeyboardButtonDelegate {
    var events: [String] = []
    var encode = true
    func keyPressed(_ key: String, modifiers: KeyModifiers) {}
    func sendRawData(_ data: Data) { events.append("raw") }
    func sendSequenceData(_ data: Data) { events.append(String(decoding: data, as: UTF8.self)) }
    func sendKeyCombo(_ combo: SequenceStep.KeyCombo) -> Bool {
        guard encode, !combo.modifiers.isEmpty else { return false }
        precondition(combo.modifiers == [.ctrl, .shift])
        precondition(combo.key == .symbol("\\"))
        events.append("encoded")
        return true
    }
}
let chord = SequenceStep.keyCombo(.init(modifiers: [.ctrl, .shift], key: .symbol("\\")))
let steps: [SequenceStep] = [chord, .keyCombo(.init(modifiers: [], key: .special(.space))), .text("S")]
let recorder = Recorder()
recorder.sendSequenceSteps(steps)
precondition(recorder.events == ["encoded", " ", "S"])
recorder.events = []
recorder.encode = false
recorder.sendSequenceSteps(steps)
precondition(recorder.events == [String(decoding: chord.terminalData(), as: UTF8.self), " ", "S"])
recorder.events = []
recorder.encode = true
recorder.sendSequenceSteps([chord])
precondition(recorder.events == ["encoded"])
recorder.events = []
recorder.sendSequenceSteps([])
precondition(recorder.events.isEmpty)
recorder.sendSequenceSteps([.text("\u{1B}"), .text("S")])
precondition(recorder.events == ["\u{1B}"])
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
precondition(recorder.events == ["\u{1B}", "S"])
print("Sequence modifier routing, fallback, ordering, and Escape delay passed")
'''
with tempfile.TemporaryDirectory() as temporary:
    script = Path(temporary) / "main.swift"
    script.write_text(source)
    subprocess.run(["swift", str(script)], check=True)
