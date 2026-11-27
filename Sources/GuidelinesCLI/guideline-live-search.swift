import Darwin
import Dispatch
import GuidelinesSearch
import Terminal
import Surface

struct GuidelineLiveSearchConfiguration:
    Sendable,
    Hashable
{
    var debounceMilliseconds: Int
    var maximumVisibleResults: Int
    var outputStream: TerminalStream

    init(
        debounceMilliseconds: Int = 50,
        maximumVisibleResults: Int = 10,
        outputStream: TerminalStream = .standardError
    ) {
        self.debounceMilliseconds = max(
            0,
            debounceMilliseconds
        )

        self.maximumVisibleResults = max(
            1,
            maximumVisibleResults
        )

        self.outputStream = outputStream
    }
}

enum GuidelineLiveSearchResult:
    Sendable
{
    case picked(
        entry: GuidelineSearchIndex.Entry,
        query: String
    )

    case cancelled(
        query: String,
        currentID: String?
    )
}

struct GuidelineLiveSearch {
    private enum Focus {
        case query
        case results
    }

    private let searchIndex: GuidelineSearchIndex
    private let configuration:
        GuidelineLiveSearchConfiguration

    init(
        searchIndex: GuidelineSearchIndex,
        configuration:
            GuidelineLiveSearchConfiguration = .init()
    ) {
        self.searchIndex = searchIndex
        self.configuration = configuration
    }

    func run(
        initialQuery: String = "",
        initialCurrentID: String? = nil
    ) throws -> GuidelineLiveSearchResult {
        let session = try TerminalSession(
            options:
                TerminalSession.Options(
                    useAlternateScreen: false,
                    hideCursor: true,
                    useRawMode: true,
                    restoreOnInterrupt: true,
                    outputStream:
                        configuration.outputStream
                )
        )

        defer {
            session.restore()
        }

        let reader = TerminalKeyReader()

        var query = initialQuery

        var results =
            query.isEmpty
            ? []
            : searchIndex.search(
                query
            )

        var navigator =
            SurfaceList.Navigator(
                count: results.count,
                selectedIndex:
                    initialSelectionIndex(
                        in: results,
                        id: initialCurrentID
                    ),
                wrapMode: .wrap
            )

        var focus: Focus = .query
        var pendingRefreshDeadline: UInt64?
        var needsRender = true

        while true {
            if needsRender {
                render(
                    query: query,
                    results: results,
                    navigator: navigator,
                    focus: focus
                )

                needsRender = false
            }

            let timeout =
                timeoutMilliseconds(
                    until:
                        pendingRefreshDeadline
                )

            guard let key = readKey(
                reader,
                timeoutMilliseconds: timeout
            ) else {
                if let deadline =
                    pendingRefreshDeadline,
                   nowNanoseconds()
                    >= deadline
                {
                    refresh(
                        query: query,
                        results: &results,
                        navigator: &navigator
                    )

                    pendingRefreshDeadline =
                        nil

                    needsRender = true
                }

                continue
            }

            if shouldFlushPendingSearch(
                for: key,
                focus: focus
            ),
               pendingRefreshDeadline != nil
            {
                refresh(
                    query: query,
                    results: &results,
                    navigator: &navigator
                )

                pendingRefreshDeadline =
                    nil

                needsRender = true
            }

            switch focus {
            case .query:
                switch key {
                case .char(
                    let character
                ):
                    if character == "q" {
                        let escapeCount =
                            trailingBackslashCount(
                                query
                            )

                        if escapeCount > 0 {
                            if escapeCount.isMultiple(
                                of: 2
                            ) {
                                query.removeLast()
                                query += character

                                scheduleRefresh(
                                    deadline:
                                        &pendingRefreshDeadline
                                )

                                needsRender = true

                                continue
                            }

                            query.removeLast()

                            return .cancelled(
                                query: query,
                                currentID:
                                    currentID(
                                        in: results,
                                        navigator:
                                            navigator
                                    )
                            )
                        }
                    }

                    query += character

                    scheduleRefresh(
                        deadline:
                            &pendingRefreshDeadline
                    )

                    needsRender = true

                case .space:
                    query += " "

                    scheduleRefresh(
                        deadline:
                            &pendingRefreshDeadline
                    )

                    needsRender = true

                case .backspace:
                    if !query.isEmpty {
                        query.removeLast()

                        scheduleRefresh(
                            deadline:
                                &pendingRefreshDeadline
                        )

                        needsRender = true
                    }

                case .control("U"):
                    guard !query.isEmpty else {
                        continue
                    }

                    query.removeAll(
                        keepingCapacity: true
                    )

                    scheduleRefresh(
                        deadline:
                            &pendingRefreshDeadline
                    )

                    needsRender = true

                case .down,
                     .control("N"),
                     .tab:
                    guard !results.isEmpty else {
                        continue
                    }

                    focus = .results
                    needsRender = true

                case .enter:
                    guard let entry =
                        currentEntry(
                            in: results,
                            navigator:
                                navigator
                        )
                    else {
                        continue
                    }

                    return .picked(
                        entry: entry,
                        query: query
                    )

                case .escape,
                     .control("D"):
                    return .cancelled(
                        query: query,
                        currentID:
                            currentID(
                                in: results,
                                navigator:
                                    navigator
                            )
                    )

                default:
                    break
                }

            case .results:
                switch key.navigationDirection(
                    on: .vertical
                ) {
                case .previous:
                    navigator.moveUp()
                    needsRender = true

                    continue

                case .next:
                    navigator.moveDown()
                    needsRender = true

                    continue

                case nil:
                    break
                }

                switch key {
                case .enter:
                    guard let entry =
                        currentEntry(
                            in: results,
                            navigator:
                                navigator
                        )
                    else {
                        continue
                    }

                    return .picked(
                        entry: entry,
                        query: query
                    )

                case .escape,
                     .char("q"),
                     .left:
                    focus = .query
                    needsRender = true

                case .backspace:
                    focus = .query

                    if !query.isEmpty {
                        query.removeLast()

                        scheduleRefresh(
                            deadline:
                                &pendingRefreshDeadline
                        )
                    }

                    needsRender = true

                case .space:
                    focus = .query
                    query += " "

                    scheduleRefresh(
                        deadline:
                            &pendingRefreshDeadline
                    )

                    needsRender = true

                case .char(
                    let character
                ):
                    focus = .query
                    query += character

                    scheduleRefresh(
                        deadline:
                            &pendingRefreshDeadline
                    )

                    needsRender = true

                case .control("U"):
                    focus = .query

                    query.removeAll(
                        keepingCapacity: true
                    )

                    scheduleRefresh(
                        deadline:
                            &pendingRefreshDeadline
                    )

                    needsRender = true

                case .control("D"):
                    return .cancelled(
                        query: query,
                        currentID:
                            currentID(
                                in: results,
                                navigator:
                                    navigator
                            )
                    )

                default:
                    break
                }
            }
        }
    }

    private func refresh(
        query: String,
        results:
            inout [
                GuidelineSearchIndex.Entry
            ],
        navigator:
            inout SurfaceList.Navigator
    ) {
        let previousID =
            currentID(
                in: results,
                navigator: navigator
            )

        results =
            query.isEmpty
            ? []
            : searchIndex.search(
                query
            )

        navigator.updateCount(
            results.count
        )

        guard !results.isEmpty else {
            return
        }

        if let previousID,
           let index =
            results.firstIndex(
                where: {
                    $0.id
                        == previousID
                }
            )
        {
            navigator.select(
                index
            )
        } else {
            navigator.select(
                0
            )
        }
    }

    private func scheduleRefresh(
        deadline: inout UInt64?
    ) {
        let milliseconds =
            configuration
                .debounceMilliseconds

        if milliseconds == 0 {
            deadline =
                nowNanoseconds()

            return
        }

        deadline =
            nowNanoseconds()
            + UInt64(
                milliseconds
            )
            * 1_000_000
    }

    private func shouldFlushPendingSearch(
        for key: SurfaceInput.Key,
        focus: Focus
    ) -> Bool {
        guard focus == .query else {
            return false
        }

        switch key {
        case .down,
             .control("N"),
             .tab,
             .enter:
            return true

        default:
            return false
        }
    }

    private func render(
        query: String,
        results:
            [
                GuidelineSearchIndex.Entry
            ],
        navigator:
            SurfaceList.Navigator,
        focus: Focus
    ) {
        let stream =
            configuration.outputStream

        let columns = max(
            20,
            Terminal.size(
                for: stream
            ).columns
        )

        Terminal.clearScreen(
            to: stream
        )

        Terminal.moveCursor(
            line: 1,
            column: 1,
            to: stream
        )

        Terminal.write(
            "Search manual"
                .ansi(
                    .bold,
                    .brightCyan
                )
                + "\n",
            to: stream
        )

        let queryCursor =
            focus == .query
            ? "|".ansi(
                .brightCyan,
                .bold
            )
            : ""

        Terminal.write(
            "\n"
                + "Search: "
                    .ansi(
                        .brightBlack
                    )
                + query
                + queryCursor
                + "\n",
            to: stream
        )

        if query.isEmpty {
            Terminal.write(
                (
                    "\nType to fuzzy-search the manual. "
                    + "\\q exits search.\n"
                )
                .ansi(
                    .brightBlack
                ),
                to: stream
            )

            Terminal.flush(
                stream
            )

            return
        }

        Terminal.write(
            "\n"
                + "\(results.count) match"
                + (
                    results.count == 1
                    ? ""
                    : "es"
                )
                + "\n\n",
            to: stream
        )

        guard !results.isEmpty else {
            Terminal.write(
                "No matching manual entries.\n"
                    .ansi(
                        .brightBlack
                    ),
                to: stream
            )

            Terminal.flush(
                stream
            )

            return
        }

        let visibleRange =
            visibleResultRange(
                count: results.count,
                selectedIndex:
                    navigator.selection
                    ?? 0
            )

        for index in visibleRange {
            let entry =
                results[index]

            let content =
                TerminalMenuRowContent(
                    title: entry.title,
                    caption: caption(
                        entry
                    )
                )

            Terminal.write(
                content.render(
                    isCurrent:
                        focus == .results
                        && navigator.selection
                            == index,
                    isEnabled: true,
                    theme: .agentic,
                    width: columns
                ),
                to: stream
            )
        }

        Terminal.write(
            (
                "\nType to refine. "
                + "Down/Tab focuses results. "
                + "Enter opens. "
                + "q from results returns to search. "
                + "\\q exits.\n"
            )
            .ansi(
                .brightBlack
            ),
            to: stream
        )

        Terminal.flush(
            stream
        )
    }

    private func caption(
        _ entry:
            GuidelineSearchIndex.Entry
    ) -> String {
        let location =
            entry.chapter.area
                .terminalTitle
            + " · "
            + entry.chapter.title

        guard
            let summary = entry.summary,
            !summary.isEmpty
        else {
            return location
        }

        return location
            + " — "
            + oneLine(
                summary
            )
    }

    private func oneLine(
        _ content: String
    ) -> String {
        content
            .split(
                whereSeparator: {
                    $0.isWhitespace
                }
            )
            .joined(
                separator: " "
            )
    }

    private func visibleResultRange(
        count: Int,
        selectedIndex: Int
    ) -> Range<Int> {
        let visibleCount = min(
            count,
            configuration
                .maximumVisibleResults
        )

        guard count > visibleCount else {
            return 0..<count
        }

        let half =
            visibleCount / 2

        let maximumStart =
            count - visibleCount

        let start = min(
            max(
                0,
                selectedIndex - half
            ),
            maximumStart
        )

        return start..<(start + visibleCount)
    }

    private func initialSelectionIndex(
        in results:
            [
                GuidelineSearchIndex.Entry
            ],
        id: String?
    ) -> Int {
        guard let id else {
            return 0
        }

        return results.firstIndex(
            where: {
                $0.id == id
            }
        ) ?? 0
    }

    private func currentEntry(
        in results:
            [
                GuidelineSearchIndex.Entry
            ],
        navigator:
            SurfaceList.Navigator
    ) -> GuidelineSearchIndex.Entry? {
        guard
            let index =
                navigator.selection,
            results.indices.contains(
                index
            )
        else {
            return nil
        }

        return results[index]
    }

    private func currentID(
        in results:
            [
                GuidelineSearchIndex.Entry
            ],
        navigator:
            SurfaceList.Navigator
    ) -> String? {
        currentEntry(
            in: results,
            navigator: navigator
        )?.id
    }

    private func trailingBackslashCount(
        _ query: String
    ) -> Int {
        query
            .reversed()
            .prefix {
                $0 == "\\"
            }
            .count
    }

    private func timeoutMilliseconds(
        until deadline: UInt64?
    ) -> Int32 {
        guard let deadline else {
            return -1
        }

        let now =
            nowNanoseconds()

        guard deadline > now else {
            return 0
        }

        let remaining =
            deadline - now

        let milliseconds =
            (
                remaining
                + 999_999
            )
            / 1_000_000

        return Int32(
            min(
                milliseconds,
                UInt64(
                    Int32.max
                )
            )
        )
    }

    private func readKey(
        _ reader: TerminalKeyReader,
        timeoutMilliseconds: Int32
    ) -> SurfaceInput.Key? {
        var descriptor =
            pollfd(
                fd:
                    reader
                        .fileDescriptor,
                events:
                    Int16(
                        POLLIN
                    ),
                revents: 0
            )

        while true {
            let status =
                poll(
                    &descriptor,
                    1,
                    timeoutMilliseconds
                )

            if status > 0 {
                return reader.readKey()
            }

            if status == 0 {
                return nil
            }

            guard errno == EINTR else {
                return nil
            }
        }
    }

    private func nowNanoseconds()
        -> UInt64
    {
        DispatchTime
            .now()
            .uptimeNanoseconds
    }
}
