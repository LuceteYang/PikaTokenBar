import Foundation

/// 부화 후보 — 진화라인 시작점(base) 종과 공식 희귀도.
struct BaseSpecies: Sendable, Codable {
    let id: Int
    let captureRate: Int    // 3(뮤츠급)~255(캐터피급), 공식 희귀도 신호
}

/// 포켓몬 라인 데이터 제공(주입 가능 — 테스트는 스텁 사용).
protocol PokeProviding: Sendable {
    func line(baseSpeciesID: Int) async throws -> EvoLine
    /// 1~5세대 base 전체 인덱스 (GraphQL 1쿼리, 디스크 캐시).
    func baseSpeciesIndex() async throws -> [BaseSpecies]
    /// 단일 종이 base(진화 시작점)면 BaseSpecies, 아니면 nil.
    /// GraphQL 인덱스 엔드포인트 장애 시 REST(pokemon-species)로 부화 후보를 뽑는 폴백용.
    func baseSpecies(id: Int) async throws -> BaseSpecies?
}

/// PokéAPI 클라이언트 — 종/진화체인을 런타임 fetch + 파싱. 포켓몬 데이터는 레포에 번들하지 않는다.
/// species 응답은 actor 캐시(다국어 이름 재사용).
actor PokeAPIClient: PokeProviding {
    static let shared = PokeAPIClient()
    private let base = URL(string: "https://pokeapi.co/api/v2")!
    private let langCodes = ["ko", "en", "ja-Hrkt", "ja"]
    private var speciesCache: [Int: SpeciesDTO] = [:]
    private var lineCache: [Int: EvoLine] = [:]   // 프리패칭 → 부화 순간 네트워크 0

    func line(baseSpeciesID: Int) async throws -> EvoLine {
        if let cached = lineCache[baseSpeciesID] { return cached }
        let baseSpecies = try await species(baseSpeciesID)
        // PokéAPI 응답의 URL — 비정상/빈 값이면 force-unwrap 대신 throw(앱은 알 상태 유지).
        guard let chainURL = Self.validatedChainURL(baseSpecies.evolution_chain.url) else {
            throw URLError(.badURL)
        }
        let chainDTO: ChainDTO = try await get(chainURL)
        let tree = node(from: chainDTO.chain)
        let rarity = Rarity.from(captureRate: baseSpecies.capture_rate,
                                 isLegendary: baseSpecies.is_legendary,
                                 isMythical: baseSpecies.is_mythical)
        // 라인의 모든 종 이름(지원 언어만)
        var names: [Int: [String: String]] = [:]
        for id in allIDs(tree) {
            let sp = try await species(id)
            var byLang: [String: String] = [:]
            for n in sp.names where langCodes.contains(n.language.name) { byLang[n.language.name] = n.name }
            names[id] = byLang
        }
        let line = EvoLine(baseID: baseSpeciesID, tree: tree, rarity: rarity, names: names)
        lineCache[baseSpeciesID] = line
        return line
    }

    // MARK: base 인덱스 (부화 후보)

    private var baseIndexCache: [BaseSpecies]?
    private var restBuildInFlight = false
    private var restBuildTried = false   // 세션당 1회 (GraphQL 다운 시 REST 인덱스 구축 트리거)
    private static let baseIndexFile: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PokeTokenBar")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("base-index.json")
    }()
    private struct BaseIndexSnapshot: Codable { let fetchedAt: Date; let entries: [BaseSpecies] }
    private struct GraphQLBaseResponse: Decodable {
        struct DataBox: Decodable { let pokemonspecies: [Row] }
        struct Row: Decodable { let id: Int; let capture_rate: Int }
        let data: DataBox
    }

    /// 1~5세대 base(진화라인 시작점) 전체 — PokéAPI GraphQL 1쿼리.
    /// 우선순위: 메모리 캐시 → 디스크 캐시(30일 TTL) → GraphQL fetch(성공 시 디스크 갱신)
    /// → TTL 지난 디스크라도 있으면 사용(오프라인 폴백). 전부 실패 시 throw(알 유지, 다음 틱 재시도).
    func baseSpeciesIndex() async throws -> [BaseSpecies] {
        if let c = baseIndexCache { return c }
        let disk = (try? Data(contentsOf: Self.baseIndexFile))
            .flatMap { try? JSONDecoder().decode(BaseIndexSnapshot.self, from: $0) }
        if let disk, Date().timeIntervalSince(disk.fetchedAt) < 30 * 86400, !disk.entries.isEmpty {
            baseIndexCache = disk.entries
            return disk.entries
        }
        do {
            let entries = try await fetchBaseIndex()
            baseIndexCache = entries
            if let data = try? JSONEncoder().encode(BaseIndexSnapshot(fetchedAt: Date(), entries: entries)) {
                try? data.write(to: Self.baseIndexFile, options: .atomic)
            }
            return entries
        } catch {
            if let disk, !disk.entries.isEmpty {   // 오프라인 — 오래된 인덱스라도 사용
                baseIndexCache = disk.entries
                return disk.entries
            }
            // GraphQL 다운 + 캐시 없음 → REST 로 인덱스를 백그라운드 구축(세션 1회).
            // 이번 부화는 per-hatch REST 폴백(chooseBaseViaREST)이 즉시 처리하고,
            // 구축이 끝나면 디스크 캐시로 남아 이후 선택이 가중·수집반영·오프라인가능으로 복귀한다.
            if !restBuildTried {
                restBuildTried = true
                Task { await self.buildBaseIndexViaREST() }
            }
            AppLog.write("base index (GraphQL) failed, no cache — REST build triggered; per-hatch fallback handles now: \(error)")
            throw error
        }
    }

    /// GraphQL base 인덱스 엔드포인트 장애 시 REST(pokemon-species/{id})로 base 인덱스를 직접 구축·영속.
    /// 한 번 성공하면 base-index.json(30일)으로 남아 이후 선택은 네트워크 없이 가중·수집반영으로 동작 →
    /// 부화가 특정 엔드포인트 생존에 영구히 묶이지 않게 하는 자가치유 캐시. PokéAPI 배려로 소규모 동시성.
    func buildBaseIndexViaREST() async {
        guard baseIndexCache == nil, !restBuildInFlight else { return }
        restBuildInFlight = true
        defer { restBuildInFlight = false }
        AppLog.write("base index: building via REST (GraphQL unavailable)…")
        var bases: [BaseSpecies] = []
        let batchSize = 6
        var start = 1
        let maxID = PokemonAssets.animatedSpeciesIDs.upperBound
        var attempted = 0
        var failed = 0
        while start <= maxID {
            let end = min(start + batchSize - 1, maxID)
            // `try?` 로 뭉개면 "base 아님(nil)"과 "요청 실패"가 구분되지 않는다 — 완성도 판정이
            // 그 차이에 걸려 있으므로 Result 로 받아 실패만 따로 센다.
            let results = await withTaskGroup(of: Result<BaseSpecies?, Error>.self) { group -> [Result<BaseSpecies?, Error>] in
                for id in start...end {
                    group.addTask {
                        do { return .success(try await self.baseSpecies(id: id)) }
                        catch { return .failure(error) }
                    }
                }
                var acc: [Result<BaseSpecies?, Error>] = []
                for await r in group { acc.append(r) }
                return acc
            }
            for r in results {
                attempted += 1
                switch r {
                case .success(let bs): if let bs { bases.append(bs) }
                case .failure:         failed += 1
                }
            }
            start += batchSize
        }
        // 네트워크가 많이 깨졌으면 빈약한 인덱스를 영속하지 않고 다음 세션 재시도.
        guard Self.shouldPersistRESTIndex(attempted: attempted, failed: failed, foundCount: bases.count) else {
            if attempted > 0, failed == 0 {
                AppLog.write("base index: REST sweep succeeded but found 0 bases — not cached, will retry next session")
            } else {
                AppLog.write("base index: REST build incomplete (\(failed)/\(attempted) failed) — not cached, will retry next session")
            }
            return
        }
        bases.sort { $0.id < $1.id }
        baseIndexCache = bases
        if let data = try? JSONEncoder().encode(BaseIndexSnapshot(fetchedAt: Date(), entries: bases)) {
            try? data.write(to: Self.baseIndexFile, options: .atomic)
        }
        AppLog.write("base index: REST build done — \(bases.count) bases persisted (offline-capable now)")
    }

    /// REST 전수 훑기 결과를 영속해도 되는가.
    ///
    /// 판정 신호는 **실패한 요청 비율**이다. "찾은 base 개수"로 판정하면 안 된다 — 그 값은 범위와
    /// 진화 구조에 따라 변해서(649 에선 약 250종, 1세대에선 약 78종) 범위를 좁히는 순간 임계값이
    /// 조용히 항상-실패로 뒤집힌다. 알고 싶은 건 "네트워크가 불안정했나"뿐이다.
    nonisolated static func isRESTIndexUsable(attempted: Int, failed: Int) -> Bool {
        guard attempted > 0 else { return false }
        return failed * 10 <= attempted   // 실패율 10% 이하만 영속
    }

    /// 실패율 판정을 통과했더라도 그대로 캐싱해선 안 되는 경우가 하나 더 있다 — 요청이 전부
    /// 성공했는데(failed == 0) base 를 하나도 못 찾은 경우다(PokéAPI 스키마 변경으로
    /// `evolves_from_species` 파싱이 깨지거나, `hasAnimatedSprite` 설정 오류 등). 그때 실패율은
    /// 0%라 `isRESTIndexUsable` 만으로는 통과해버리고, 빈 배열을 캐싱하면 `baseIndexCache != nil`
    /// 이 되어 이번 세션 내내 재시도가 막힌다(REST 자가치유 자신도, GraphQL 실패 경로도).
    /// 그래서 "실패율" 과 "뭔가는 찾았는가" 를 함께 봐야 영속 여부가 결정된다.
    nonisolated static func shouldPersistRESTIndex(attempted: Int, failed: Int, foundCount: Int) -> Bool {
        isRESTIndexUsable(attempted: attempted, failed: failed) && foundCount > 0
    }

    /// base 후보 질의. "base" 는 `evolves_from IS NULL` 만으로 부족하다 — 피카츄(#25)의 진화 전은
    /// 피츄(#172)라, 범위를 1세대로 좁히면 피카츄·삐삐·푸린·시라소몬·홍수몬·럭키·마임맨·루주라·
    /// 에레브·마그마·잠만보 11종 라인이 통째로 부화 풀에서 사라진다.
    /// **진화 전이 범위 밖이면 그 종이 곧 이 범위의 시작점**이므로 `_gt: maxID` 가지를 함께 둔다.
    /// 메타몽은 위장 리빌 전용이라 일반 부화 풀에서 제외(`_neq`).
    nonisolated static func baseIndexQuery(maxID: Int, dittoID: Int) -> String {
        "{ pokemonspecies(where: {_and: [{id: {_lte: \(maxID), _neq: \(dittoID)}}, "
            + "{_or: [{evolves_from_species_id: {_is_null: true}}, "
            + "{evolves_from_species_id: {_gt: \(maxID)}}]}]}, order_by: {id: asc}) "
            + "{ id capture_rate } }"
    }

    private func fetchBaseIndex() async throws -> [BaseSpecies] {
        // 공식 GraphQL — base 후보 + id ≤ maxID(사용 범위 상한).
        // "base" 는 evolves_from IS NULL 만으로는 부족하다. 피카츄(#25)의 진화 전은 피츄(#172)라
        // 범위를 1세대로 좁히면 피카츄·삐삐·푸린·시라소몬·홍수몬·럭키·마임맨·루주라·에레브·마그마·
        // 잠만보 11종 라인이 통째로 부화 풀에서 사라진다(모두 진화 전이 2~4세대 베이비).
        // **진화 전이 범위 밖이면 그 종이 곧 이 범위의 시작점**이므로
        // `_gt: maxID` 를 base 조건에 함께 넣는다.
        guard let url = URL(string: "https://graphql.pokeapi.co/v1beta2") else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let query = Self.baseIndexQuery(maxID: PokemonAssets.animatedSpeciesIDs.upperBound,
                                        dittoID: PokemonOdds.dittoSpeciesID)
        req.httpBody = try JSONSerialization.data(withJSONObject: ["query": query])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let decoded = try JSONDecoder().decode(GraphQLBaseResponse.self, from: data)
        let entries = decoded.data.pokemonspecies.map { BaseSpecies(id: $0.id, captureRate: $0.capture_rate) }
        guard !entries.isEmpty else { throw URLError(.cannotParseResponse) }
        return entries
    }

    private func species(_ id: Int) async throws -> SpeciesDTO {
        if let c = speciesCache[id] { return c }
        let dto: SpeciesDTO = try await get(base.appendingPathComponent("pokemon-species/\(id)"))
        speciesCache[id] = dto
        return dto
    }

    /// REST 폴백 — 단일 종 상세(pokemon-species/{id})로 base 여부·capture_rate 판정.
    /// GraphQL base 인덱스가 죽어도 REST(pokeapi.co/api/v2)는 별개 엔드포인트라 동작한다.
    func baseSpecies(id: Int) async throws -> BaseSpecies? {
        guard id != PokemonOdds.dittoSpeciesID else { return nil }   // 메타몽은 위장 리빌 전용 — 일반 부화 제외
        let dto = try await species(id)
        // GraphQL 인덱스와 **같은 base 규칙**을 써야 한다 — 판정 자체는 순수 함수로 분리(테스트용).
        let preEvolutionID = dto.evolves_from_species.map { Self.id(from: $0.url ?? "") }
        guard Self.isBaseCandidate(preEvolutionID: preEvolutionID) else { return nil }
        return BaseSpecies(id: id, captureRate: dto.capture_rate)
    }

    /// 이 종이 **이 범위의 base** 인가. 세 경우로 갈린다:
    ///  - 진화 전이 없다 → 원래 시작점이므로 base.
    ///  - 진화 전이 범위 밖이다(피카츄 #25 ← 피츄 #172) → 이 종이 이 범위의 시작점이므로 base.
    ///  - 진화 전이 범위 안이다 → 진화 중간체이므로 base 아님.
    ///
    /// `preEvolutionID == 0` 은 URL 파싱 실패다. 이걸 그냥 두면 `hasAnimatedSprite(0)` 이 false(=범위 밖)로
    /// 읽혀 **진화 중간체가 base 로 승격되고 부화 후보가 된다**. 판정 불가는 보수적으로 base 아님으로 본다.
    nonisolated static func isBaseCandidate(preEvolutionID: Int?) -> Bool {
        guard let preEvolutionID else { return true }
        guard preEvolutionID > 0 else { return false }
        return !PokemonAssets.hasAnimatedSprite(speciesID: preEvolutionID)
    }

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func node(from link: ChainLink) -> EvoNode {
        EvoNode(speciesID: Self.id(from: link.species.url ?? ""),
                children: link.evolves_to.map(node(from:)))
    }
    private func allIDs(_ n: EvoNode) -> [Int] { [n.speciesID] + n.children.flatMap(allIDs) }

    static func id(from speciesURL: String) -> Int {
        // ".../pokemon-species/{id}/"
        let parts = speciesURL.split(separator: "/").filter { !$0.isEmpty }
        return Int(parts.last ?? "0") ?? 0
    }

    /// PokéAPI evolution_chain URL 검증(SSRF 가드) — 서버 제어 문자열이므로 https + pokeapi.co 로 고정해
    /// 응답 변조 시 임의 호스트 fetch 를 막는다. 부적합하면 nil(호출부가 throw → 앱은 알 상태 유지).
    static func validatedChainURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), url.scheme == "https", url.host == "pokeapi.co" else { return nil }
        return url
    }
}

// MARK: - DTO (PokéAPI 응답 부분 디코드)

struct SpeciesDTO: Decodable, Sendable {
    let capture_rate: Int
    let is_legendary: Bool
    let is_mythical: Bool
    let names: [NameDTO]
    let evolution_chain: URLRef
    let evolves_from_species: NamedRef?   // nil = 진화라인 시작점(base)
}
struct NameDTO: Decodable, Sendable { let name: String; let language: NamedRef }
struct NamedRef: Decodable, Sendable { let name: String; let url: String? }
struct URLRef: Decodable, Sendable { let url: String }
struct ChainDTO: Decodable, Sendable { let chain: ChainLink }
struct ChainLink: Decodable, Sendable {
    let species: NamedRef
    let evolves_to: [ChainLink]
}
