//
//  FlyingCarpetTests.swift
//  FlyingCarpetTests
//
//  Created by Theron on 5/25/22.
//

import XCTest
import Network
import UIKit
@testable import FlyingCarpet

// The protocol known-answer vectors live in the macOS target (macOS/FlyingCarpetTests). What is
// here is the iOS half of two fixes that were reported on iOS hardware and can only be exercised
// on it: the bounded Noise receive buffer (#142), which failed on the iOS receiver, and the QR
// display layout (#141), which is UIKit and has no macOS counterpart.

// MARK: - #142, bounded Noise receive buffer

// A Noise transport must hold at most one decrypted record, however much a caller asks for. The
// buffer used to be a single Data appended to until it reached the requested length and then
// drained from the front; draining the front of a Data does not reclaim the front of its storage,
// so on a receiver the footprint tracked bytes received rather than bytes in flight. An iPad 9
// (1850 MiB per-process limit) was killed by jetsam about 1.1 GB into a 3.75 GiB transfer.
//
// The same two tests are in the macOS target against the same shared/Noise.swift. These run them
// on the platform that actually failed.
final class NoiseConnectionBufferTests: XCTestCase {

    // Generates a valid Noise record stream on demand rather than holding one in memory, so the
    // footprint measured below belongs to the code under test and not to the fixture.
    private final class GeneratingConnection: TCPConnectionProtocol {
        private let cipher: NoiseCipherState
        private let payload: Data
        private var recordsLeft: Int
        private var pending = Data()
        private var pendingPos = 0
        var beforeRead: (() -> Void)?

        init(cipher: NoiseCipherState, payload: Data, records: Int) {
            self.cipher = cipher
            self.payload = payload
            self.recordsLeft = records
        }

        var connection: NWConnection {
            fatalError("GeneratingConnection has no NWConnection; these tests never reach one")
        }

        func write(data: Data) async throws {}
        func disconnect() {}
        func forceDisconnect() {}

        func receiveNBytes(n: Int) async throws -> Data {
            beforeRead?()
            var out = Data(capacity: n)
            while out.count < n {
                if pendingPos >= pending.count {
                    guard recordsLeft > 0 else { throw TransferError.TCPReadError }
                    recordsLeft -= 1
                    let record = try cipher.encrypt(ad: Data(), plaintext: payload)
                    var framed = Data(capacity: record.count + 2)
                    framed.append(UInt8((record.count >> 8) & 0xff))
                    framed.append(UInt8(record.count & 0xff))
                    framed.append(record)
                    pending = framed
                    pendingPos = 0
                }
                let take = min(pending.count - pendingPos, n - out.count)
                out.append(pending[pendingPos ..< (pendingPos + take)])
                pendingPos += take
            }
            return out
        }
    }

    private func cipherPair(_ password: String) throws -> (NoiseCipherState, NoiseCipherState) {
        let psk = derivePsk(password)
        let initHS = try NoiseHandshakeState(role: .initiator, psk: psk)
        let respHS = try NoiseHandshakeState(role: .responder, psk: psk)
        _ = try respHS.readMessage(initHS.writeMessage())
        _ = try initHS.readMessage(respHS.writeMessage())
        let (initSend, _) = initHS.split()
        let (_, respRecv) = respHS.split()
        return (initSend, respRecv)
    }

    private func makeConnection(streaming bytes: Int) throws -> (NoiseConnection, GeneratingConnection) {
        let (send, recv) = try cipherPair("bounded buffer")
        let payload = Data(repeating: 0xA5, count: NOISE_MAX_PLAINTEXT)
        let generator = GeneratingConnection(
            cipher: send, payload: payload, records: bytes / NOISE_MAX_PLAINTEXT + 2
        )
        return (NoiseConnection(inner: generator, sendCipher: send, recvCipher: recv), generator)
    }

    // phys_footprint is the figure jetsam reads, and what the #142 report quotes as rpages.
    private func physFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    // Deterministic form. Samples the buffer where it is largest — just before each frame is
    // pulled — and requires it to stay within one record whatever the caller asked for. Under the
    // old buffer a single 5 MB read grew it to the full 5 MB before draining.
    func testBufferNeverExceedsOneRecord() async throws {
        let chunks = 8
        let (connection, generator) = try makeConnection(streaming: CHUNK_SIZE * chunks)

        var peak = 0
        generator.beforeRead = { [weak connection] in
            if let connection { peak = max(peak, connection.bufferedByteCount) }
        }

        var received = 0
        for _ in 0 ..< chunks {
            let chunk = try await connection.receiveNBytes(n: CHUNK_SIZE)
            XCTAssertEqual(chunk.count, CHUNK_SIZE)
            received += chunk.count
            peak = max(peak, connection.bufferedByteCount)
        }

        XCTAssertEqual(received, CHUNK_SIZE * chunks)
        XCTAssertLessThanOrEqual(
            peak, NOISE_MAX_MESSAGE,
            "buffered \(peak) bytes; a Noise transport must never carry more than one record"
        )
    }

    // The bytes handed back must be the bytes sent, in order, across the record boundaries the
    // position index now walks — a bounded buffer that corrupts the stream is no fix.
    func testStreamIsReassembledAcrossRecordBoundaries() async throws {
        let (send, recv) = try cipherPair("record boundaries")
        // three records' worth, so reads land mid-record in both directions
        let payload = Data(repeating: 0xA5, count: NOISE_MAX_PLAINTEXT)
        let generator = GeneratingConnection(cipher: send, payload: payload, records: 4)
        let connection = NoiseConnection(inner: generator, sendCipher: send, recvCipher: recv)

        // an odd size that straddles record boundaries rather than aligning to them
        let readSize = NOISE_MAX_PLAINTEXT / 2 + 777
        var assembled = Data()
        for _ in 0 ..< 6 {
            assembled.append(try await connection.receiveNBytes(n: readSize))
        }

        XCTAssertEqual(assembled.count, readSize * 6)
        XCTAssertEqual(
            assembled, Data(repeating: 0xA5, count: readSize * 6),
            "reassembled stream does not match what was sent"
        )
    }

    // Symptom form. Streams well past where the iPad died and requires the process footprint to
    // stay flat. Touches no internals, so it runs against the pre-fix buffer too — this is the one
    // to check out the old Noise.swift and run if the mechanism ever needs confirming.
    func testFootprintStaysFlatAcrossALargeTransfer() async throws {
        let chunks = 64                       // 320 MB
        let (connection, _) = try makeConnection(streaming: CHUNK_SIZE * chunks)

        // one chunk first, so one-off allocations land before the baseline is taken
        _ = try await connection.receiveNBytes(n: CHUNK_SIZE)
        let baseline = physFootprint()
        try XCTSkipIf(baseline == 0, "task_info(TASK_VM_INFO) unavailable")

        for _ in 1 ..< chunks {
            _ = try await connection.receiveNBytes(n: CHUNK_SIZE)
        }

        let growth = max(physFootprint(), baseline) - baseline
        // Deliberately loose: a few chunks of transient allocation is fine, growth proportional
        // to the volume streamed is not.
        XCTAssertLessThan(
            growth, 64 << 20,
            // parenthesised: >> binds tighter than * in Swift, so the unparenthesised form
            // reports "0 MB" for any transfer under 1 MiB * chunks
            "footprint grew \(growth >> 20) MB while streaming \((CHUNK_SIZE * chunks) >> 20) MB"
        )
    }
}

// MARK: - #141, QR display layout

// The password dialog is presented as a page sheet. Its stack used to be centered vertically with
// no constraint against the frame, and alignment .fill gave the square QR the full sheet width, so
// on a sheet wider than it is tall the content overflowed at both ends: the instructions were cut
// off and "Done" was half visible and untappable.
//
// These lay the view out at fixed sizes rather than trusting whichever sheet the running device
// happens to produce, so the short-wide case is covered on any simulator.
final class QRDisplayLayoutTests: XCTestCase {

    private func layout(width: CGFloat, height: CGFloat) -> QRDisplayViewController {
        let vc = QRDisplayViewController()
        vc.password = "Bx7Kq2mR9t"
        // a window rather than a bare view, so the safe area layout guide is real
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: height))
        window.rootViewController = vc
        window.isHidden = false
        vc.view.frame = window.bounds
        vc.view.layoutIfNeeded()
        return vc
    }

    private func firstDescendant<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        for subview in view.subviews {
            if let match = subview as? T { return match }
            if let match = firstDescendant(type, in: subview) { return match }
        }
        return nil
    }

    private func descendants<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        view.subviews.flatMap { subview -> [T] in
            ((subview as? T).map { [$0] } ?? []) + descendants(type, in: subview)
        }
    }

    private func doneButton(in view: UIView) -> UIButton? {
        for subview in view.subviews {
            if let button = subview as? UIButton, button.title(for: .normal) == "Done" {
                return button
            }
            if let button = doneButton(in: subview) { return button }
        }
        return nil
    }

    private func scrollAncestor(of view: UIView, below root: UIView) -> UIScrollView? {
        var next = view.superview
        while let current = next, current !== root {
            if let scroll = current as? UIScrollView { return scroll }
            next = current.superview
        }
        return nil
    }

    // Where the user can actually get to this view, and the area it has to stay inside to be
    // seen. Inside a scroll view that is the scrollable content; otherwise it is the sheet
    // itself, and anything outside is clipped with no way to reach it.
    //
    // Deliberately phrased against what the user can see rather than against a scroll view
    // being present, so it fails on the pre-fix layout for the reason the report gave — Done
    // hanging off the bottom — and not merely because the hierarchy changed shape.
    private func reachable(_ view: UIView, in root: UIView) -> (frame: CGRect, within: CGRect) {
        if let scroll = scrollAncestor(of: view, below: root) {
            return (view.convert(view.bounds, to: scroll),
                    CGRect(origin: .zero, size: scroll.contentSize))
        }
        return (view.convert(view.bounds, to: root), root.bounds)
    }

    private func ambiguousViews(in view: UIView, path: String = "root") -> [String] {
        var found: [String] = []
        if view.hasAmbiguousLayout { found.append(path) }
        for (index, subview) in view.subviews.enumerated() {
            found += ambiguousViews(in: subview, path: "\(path) > [\(index)] \(type(of: subview))")
        }
        return found
    }

    private func assertLaysOutCleanly(
        width: CGFloat, height: CGFloat, _ label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let vc = layout(width: width, height: height)
        let root = vc.view!

        guard let image = firstDescendant(UIImageView.self, in: root),
              let done = doneButton(in: root) else {
            return XCTFail("\(label): QR image or Done button not found", file: file, line: line)
        }

        // #141 proper: "Done" was clipped by the bottom of the sheet and could not be tapped.
        // It is never allowed to be scrollable, so it is measured against the sheet directly.
        let doneFrame = done.convert(done.bounds, to: root)
        XCTAssertTrue(
            root.bounds.contains(doneFrame),
            "\(label): Done \(doneFrame) is not fully inside the sheet \(root.bounds)",
            file: file, line: line
        )
        XCTAssertGreaterThanOrEqual(doneFrame.height, 44, "\(label): Done below the 44pt minimum",
                                    file: file, line: line)

        // The rest was clipped off the top and bottom of the sheet. Each piece must be somewhere
        // the user can reach it: on screen, or scrolled to.
        var pieces: [(String, UIView)] = [("QR code", image)]
        for label in descendants(UILabel.self, in: root) where !label.isDescendant(of: done) {
            pieces.append((label.text?.prefix(24).description ?? "label", label))
        }
        for (name, piece) in pieces {
            let (frame, within) = reachable(piece, in: root)
            XCTAssertTrue(
                within.insetBy(dx: -0.5, dy: -0.5).contains(frame),
                "\(label): \"\(name)\" at \(frame) is outside the reachable area \(within)",
                file: file, line: line
            )
        }

        // the QR shrinks to fit a short sheet instead of overflowing it
        let visibleHeight = scrollAncestor(of: image, below: root)?.frame.height ?? root.bounds.height
        XCTAssertLessThanOrEqual(
            image.frame.height, visibleHeight * 0.55 + 0.5,
            "\(label): QR is \(image.frame.height)pt tall in a \(visibleHeight)pt sheet",
            file: file, line: line
        )
        XCTAssertLessThanOrEqual(image.frame.width, 480.5,
                                 "\(label): QR is wider than the image generated", file: file, line: line)
        XCTAssertEqual(image.frame.width, image.frame.height, accuracy: 0.5,
                       "\(label): QR is not square", file: file, line: line)
        XCTAssertGreaterThan(image.frame.width, 0, "\(label): QR collapsed", file: file, line: line)

        // anything that does scroll must do so only vertically
        if let scroll = firstDescendant(UIScrollView.self, in: root) {
            XCTAssertTrue(
                root.bounds.contains(scroll.frame.insetBy(dx: 0.5, dy: 0.5)),
                "\(label): scroll view \(scroll.frame) is not inside the sheet \(root.bounds)",
                file: file, line: line
            )
            XCTAssertLessThanOrEqual(scroll.frame.maxY, doneFrame.minY + 0.5,
                                     "\(label): scroll view overlaps Done", file: file, line: line)
            XCTAssertLessThanOrEqual(
                scroll.contentSize.width, scroll.frame.width + 0.5,
                "\(label): content is \(scroll.contentSize.width) wide in a \(scroll.frame.width) frame, so it scrolls sideways",
                file: file, line: line
            )
        }

        let ambiguous = ambiguousViews(in: root)
        XCTAssertTrue(ambiguous.isEmpty, "\(label): ambiguous layout at \(ambiguous)",
                      file: file, line: line)
    }

    // The reported case: an iPad page sheet, wider than it is tall.
    func testShortWideSheetDoesNotClip() {
        assertLaysOutCleanly(width: 704, height: 432, "iPad page sheet, short and wide")
    }

    func testTallSheetDoesNotClip() {
        assertLaysOutCleanly(width: 704, height: 940, "iPad page sheet, tall")
    }

    func testPhoneSizedSheetDoesNotClip() {
        assertLaysOutCleanly(width: 393, height: 759, "iPhone sheet")
    }

    // Slide Over and a landscape phone: the tightest heights the sheet can be given.
    func testVeryShortSheetDoesNotClip() {
        assertLaysOutCleanly(width: 852, height: 320, "landscape phone")
        assertLaysOutCleanly(width: 320, height: 400, "narrow and short")
    }

    // What the sheet actually is on the running device, whatever that is. Guards against the
    // fixed sizes above drifting from any real presentation.
    func testAsActuallyPresented() {
        let host = UIViewController()
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = host
        window.makeKeyAndVisible()

        let vc = QRDisplayViewController()
        vc.password = "Bx7Kq2mR9t"
        let presented = expectation(description: "presented")
        host.present(vc, animated: false) { presented.fulfill() }
        wait(for: [presented], timeout: 5)

        vc.view.layoutIfNeeded()
        let root = vc.view!
        print("QR sheet presented at \(root.bounds.size) on \(UIDevice.current.model)")

        guard let done = doneButton(in: root) else { return XCTFail("Done button not found") }
        let doneFrame = done.convert(done.bounds, to: root)
        XCTAssertTrue(
            root.bounds.contains(doneFrame),
            "Done \(doneFrame) is not fully inside the presented sheet \(root.bounds)"
        )
        XCTAssertTrue(ambiguousViews(in: root).isEmpty,
                      "ambiguous layout at \(ambiguousViews(in: root))")
    }
}
