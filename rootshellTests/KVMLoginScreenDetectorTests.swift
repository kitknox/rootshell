import XCTest

final class KVMLoginScreenDetectorTests: XCTestCase {

    private func line(_ text: String, x: CGFloat = 0.5, y: CGFloat = 0.3, confidence: Float = 0.9) -> KVMLoginTextLine {
        KVMLoginTextLine(text: text, confidence: confidence, bounds: CGRect(x: x - 0.05, y: y - 0.01, width: 0.1, height: 0.02))
    }

    private func detects(_ lines: [KVMLoginTextLine]) -> Bool {
        KVMLoginScreenDetector.analyze(lines).isLoginScreen
    }

    func testMacLockScreen() {
        XCTAssertTrue(detects([line("12:41", y: 0.85), line("Kit"), line("Enter Password", y: 0.12)]))
        XCTAssertTrue(detects([line("Password"), line("Touch ID or Enter Password".lowercased(), y: 0.1)]))
    }

    func testWindowsPINScreen() {
        XCTAssertTrue(detects([line("PIN"), line("I forgot my PIN", y: 0.4), line("Sign-in options", y: 0.35)]))
    }

    func testLinuxUnlockDialog() {
        XCTAssertTrue(detects([line("Password:"), line("Cancel", x: 0.4, y: 0.25), line("Unlock", x: 0.6, y: 0.25)]))
    }

    func testPreBootPromptCountsAnywhere() {
        XCTAssertTrue(detects([line("BitLocker", x: 0.06, y: 0.95), line("Enter the password to unlock this drive", x: 0.2, y: 0.9)]))
        XCTAssertTrue(detects([line("Please enter passphrase for disk nvme0n1p3_crypt:", x: 0.1, y: 0.95)]))
    }

    func testDesktopPasswordTextIsNotALoginScreen() {
        XCTAssertFalse(detects([line("Change Password…"), line("Cancel", y: 0.25)]))
        XCTAssertFalse(detects([line("Enter password", x: 0.95, y: 0.9)]), "a phrase off to the side is a window, not a login screen")
        XCTAssertFalse(detects([line("Enter password", confidence: 0.2)]))
    }

    func testShortWordsMatchWholeWordsOnly() {
        XCTAssertFalse(detects([line("Spinning up"), line("Cancel", y: 0.25), line("Restart", y: 0.2)]))
        XCTAssertFalse(KVMLoginScreenDetector.contains("spinning", "pin"))
        XCTAssertTrue(KVMLoginScreenDetector.contains("enter pin", "pin"))
        XCTAssertTrue(KVMLoginScreenDetector.contains("パスワードを入力してください", "パスワードを入力"))
    }

    func testNormalizeFoldsCaseAccentsAndPunctuation() {
        XCTAssertEqual(KVMLoginScreenDetector.normalize("Changer d’utilisateur…"), "changer d utilisateur")
        XCTAssertEqual(KVMLoginScreenDetector.normalize("Contraseña"), "contrasena")
    }
}
