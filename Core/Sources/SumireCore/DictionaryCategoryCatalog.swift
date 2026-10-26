import Foundation

/// Distribution taxonomy pinned to the v1.7.277 manifest; identifiers are relative dictionary paths.
public enum DictionaryCategoryCatalog {
    public struct Category: Identifiable, Equatable, Sendable {
        public let id: String
        public let label: String
        public let legacyFamilies: [String]
    }
    public static let selectionKey = "dictionary.categoryIDs"
    public static let releaseMarker = "release-categories-v1.7.277"
    public static let legacyIDs = ["person", "character", "mythological_figure", "place", "address", "station", "facility", "transport_route", "organization", "lineage", "product", "vehicle", "event", "award", "agreement", "initiative", "term", "work_franchise", "work_manga", "work_anime", "work_film", "work_program", "work_book", "work_game", "work_music", "work_stage", "work_periodical", "work_other", "kampo", "medical"]
    public static let legacyLabels: [String: String] = ["address": "住所", "agreement": "条約・協定", "award": "賞", "character": "キャラクター", "event": "出来事", "facility": "施設", "initiative": "事業・計画", "kampo": "漢方", "lineage": "家系", "medical": "医学", "mythological_figure": "神話の人物", "organization": "組織", "person": "人名", "place": "地名", "product": "製品", "station": "駅", "term": "用語", "transport_route": "交通路線", "vehicle": "乗り物", "work_anime": "アニメ", "work_book": "書籍", "work_film": "映画", "work_franchise": "作品シリーズ", "work_game": "ゲーム", "work_manga": "漫画", "work_music": "音楽", "work_other": "その他の作品", "work_periodical": "定期刊行物", "work_program": "番組", "work_stage": "舞台"]
    public static let categories: [Category] = [
        .init(id: "character", label: "架空キャラクター", legacyFamilies: ["character"]),
        .init(id: "mythological_figure", label: "神話・伝承の存在", legacyFamilies: ["mythological_figure"]),
        .init(id: "place", label: "地名", legacyFamilies: ["place"]),
        .init(id: "address", label: "住所", legacyFamilies: ["address"]),
        .init(id: "station", label: "駅・停留所", legacyFamilies: ["station"]),
        .init(id: "facility/religious/shrine", label: "神社・神宮", legacyFamilies: ["facility"]),
        .init(id: "facility/religious/temple", label: "寺院", legacyFamilies: ["facility"]),
        .init(id: "facility/religious/church", label: "教会・礼拝堂", legacyFamilies: ["facility"]),
        .init(id: "facility/religious/monastery", label: "修道院・宗教共同体施設", legacyFamilies: ["facility"]),
        .init(id: "facility/education/school", label: "学校", legacyFamilies: ["facility"]),
        .init(id: "facility/education/preschool", label: "保育・幼児教育施設", legacyFamilies: ["facility"]),
        .init(id: "facility/education/university", label: "大学・高等教育施設", legacyFamilies: ["facility"]),
        .init(id: "facility/education/research", label: "研究施設", legacyFamilies: ["facility"]),
        .init(id: "facility/healthcare/hospital", label: "病院", legacyFamilies: ["facility"]),
        .init(id: "facility/healthcare/clinic", label: "診療所・専門医療施設", legacyFamilies: ["facility"]),
        .init(id: "facility/healthcare/care", label: "介護・福祉施設", legacyFamilies: ["facility"]),
        .init(id: "facility/public/government", label: "官公庁・行政窓口", legacyFamilies: ["facility"]),
        .init(id: "facility/public/police_fire", label: "警察・消防・防災", legacyFamilies: ["facility"]),
        .init(id: "facility/public/judicial", label: "司法・矯正施設", legacyFamilies: ["facility"]),
        .init(id: "facility/public/postal", label: "郵便施設", legacyFamilies: ["facility"]),
        .init(id: "facility/cultural/museum", label: "博物館・資料館", legacyFamilies: ["facility"]),
        .init(id: "facility/cultural/art_museum", label: "美術館・ギャラリー", legacyFamilies: ["facility"]),
        .init(id: "facility/cultural/library", label: "図書館・文書館", legacyFamilies: ["facility"]),
        .init(id: "facility/cultural/memorial", label: "記念館・文化会館", legacyFamilies: ["facility"]),
        .init(id: "facility/entertainment/theater", label: "劇場・演芸場", legacyFamilies: ["facility"]),
        .init(id: "facility/entertainment/cinema", label: "映画館", legacyFamilies: ["facility"]),
        .init(id: "facility/entertainment/live_venue", label: "ライブ・興行会場", legacyFamilies: ["facility"]),
        .init(id: "facility/entertainment/amusement", label: "遊園地・娯楽施設", legacyFamilies: ["facility"]),
        .init(id: "facility/sports/stadium", label: "球場・競技場", legacyFamilies: ["facility"]),
        .init(id: "facility/sports/gymnasium", label: "体育館・運動施設", legacyFamilies: ["facility"]),
        .init(id: "facility/sports/golf", label: "ゴルフ場", legacyFamilies: ["facility"]),
        .init(id: "facility/sports/ski", label: "スキー場・雪上競技施設", legacyFamilies: ["facility"]),
        .init(id: "facility/sports/aquatic", label: "プール・水上スポーツ施設", legacyFamilies: ["facility"]),
        .init(id: "facility/commercial/shopping", label: "商業施設・百貨店", legacyFamilies: ["facility"]),
        .init(id: "facility/commercial/restaurant", label: "飲食店", legacyFamilies: ["facility"]),
        .init(id: "facility/commercial/market", label: "市場・商店", legacyFamilies: ["facility"]),
        .init(id: "facility/hospitality/hotel", label: "ホテル・宿泊施設", legacyFamilies: ["facility"]),
        .init(id: "facility/hospitality/inn", label: "旅館・民宿", legacyFamilies: ["facility"]),
        .init(id: "facility/hospitality/hot_spring", label: "温泉・入浴施設", legacyFamilies: ["facility"]),
        .init(id: "facility/transport/airport", label: "空港・航空施設", legacyFamilies: ["facility"]),
        .init(id: "facility/transport/harbor", label: "港湾・船舶施設", legacyFamilies: ["facility"]),
        .init(id: "facility/transport/railway_facility", label: "鉄道設備", legacyFamilies: ["facility"]),
        .init(id: "facility/transport/road_facility", label: "道路・自動車交通施設", legacyFamilies: ["facility"]),
        .init(id: "facility/transport/parking", label: "駐車・車庫施設", legacyFamilies: ["facility"]),
        .init(id: "facility/infrastructure/bridge", label: "橋梁", legacyFamilies: ["facility"]),
        .init(id: "facility/infrastructure/tunnel", label: "トンネル", legacyFamilies: ["facility"]),
        .init(id: "facility/infrastructure/dam", label: "ダム・堰", legacyFamilies: ["facility"]),
        .init(id: "facility/infrastructure/water_control", label: "水門・水路・治水設備", legacyFamilies: ["facility"]),
        .init(id: "facility/industrial/factory", label: "工場・製造施設", legacyFamilies: ["facility"]),
        .init(id: "facility/industrial/power", label: "発電・エネルギー施設", legacyFamilies: ["facility"]),
        .init(id: "facility/industrial/logistics", label: "物流・倉庫施設", legacyFamilies: ["facility"]),
        .init(id: "facility/industrial/communications", label: "通信設備", legacyFamilies: ["facility"]),
        .init(id: "facility/recreation/park_garden", label: "公園・庭園", legacyFamilies: ["facility"]),
        .init(id: "facility/recreation/zoo_aquarium", label: "動物園・水族館", legacyFamilies: ["facility"]),
        .init(id: "facility/recreation/outdoor_nature", label: "自然体験・レジャー施設", legacyFamilies: ["facility"]),
        .init(id: "facility/heritage/castle", label: "城郭・宮殿", legacyFamilies: ["facility"]),
        .init(id: "facility/heritage/archaeological_site", label: "古墳・遺跡", legacyFamilies: ["facility"]),
        .init(id: "facility/heritage/historic_residence", label: "歴史的住宅・邸宅", legacyFamilies: ["facility"]),
        .init(id: "facility/residential/housing_complex", label: "団地・住宅群", legacyFamilies: ["facility"]),
        .init(id: "facility/residential/condominium", label: "マンション・集合住宅", legacyFamilies: ["facility"]),
        .init(id: "facility/residential/mixed_use_building", label: "複合建築物", legacyFamilies: ["facility"]),
        .init(id: "facility/military/base", label: "基地・駐屯地", legacyFamilies: ["facility"]),
        .init(id: "facility/military/garrison", label: "兵営・防衛拠点", legacyFamilies: ["facility"]),
        .init(id: "facility/military/training_ground", label: "演習・訓練施設", legacyFamilies: ["facility"]),
        .init(id: "transport_route", label: "交通路線", legacyFamilies: ["transport_route"]),
        .init(id: "organization", label: "組織", legacyFamilies: ["organization"]),
        .init(id: "lineage", label: "家系・氏族", legacyFamilies: ["lineage"]),
        .init(id: "product", label: "商品・サービス", legacyFamilies: ["product"]),
        .init(id: "vehicle", label: "車両・船舶", legacyFamilies: ["vehicle"]),
        .init(id: "event/occasion/organized_event", label: "催し・行事", legacyFamilies: ["event"]),
        .init(id: "event/occasion/observance", label: "記念日・啓発日", legacyFamilies: ["event"]),
        .init(id: "event/occasion/exam_qualification", label: "試験・検定", legacyFamilies: ["event"]),
        .init(id: "event/incident/natural_disaster", label: "自然災害", legacyFamilies: ["event"]),
        .init(id: "event/incident/social_issue_litigation", label: "社会問題・騒動・訴訟", legacyFamilies: ["event"]),
        .init(id: "event/history/conflict", label: "歴史的紛争・政変", legacyFamilies: ["event"]),
        .init(id: "award", label: "賞", legacyFamilies: ["award"]),
        .init(id: "agreement", label: "条約・協定", legacyFamilies: ["agreement"]),
        .init(id: "initiative", label: "事業・キャンペーン", legacyFamilies: ["initiative"]),
        .init(id: "term/general/products_daily_goods", label: "商品・日用品（一般名称）", legacyFamilies: ["term"]),
        .init(id: "term/general/food_drink_cooking", label: "食品・飲料・料理", legacyFamilies: ["term"]),
        .init(id: "term/general/internet_slang_culture", label: "ネットスラング・ネット文化", legacyFamilies: ["term"]),
        .init(id: "term/general/neologisms_trends_youth_language", label: "新語・流行語・若者言葉", legacyFamilies: ["term"]),
        .init(id: "term/general/other_general", label: "その他の一般語", legacyFamilies: ["term"]),
        .init(id: "term/specialist/information_communications", label: "情報・通信", legacyFamilies: ["term"]),
        .init(id: "term/specialist/mathematics_physics", label: "数学・物理", legacyFamilies: ["term"]),
        .init(id: "term/specialist/chemistry_life_sciences", label: "化学・生命科学", legacyFamilies: ["term"]),
        .init(id: "term/specialist/engineering_technology", label: "工学・技術", legacyFamilies: ["term"]),
        .init(id: "term/specialist/earth_environment_resources", label: "地球・環境・資源", legacyFamilies: ["term"]),
        .init(id: "term/specialist/economics_management", label: "経済・経営", legacyFamilies: ["term"]),
        .init(id: "term/specialist/law_politics", label: "法律・政治", legacyFamilies: ["term"]),
        .init(id: "term/specialist/humanities_social_sciences", label: "人文・社会科学", legacyFamilies: ["term"]),
        .init(id: "term/specialist/culture_arts_sports", label: "文化・芸術・スポーツ", legacyFamilies: ["term"]),
        .init(id: "term/specialist/transport_safety_defense", label: "交通・安全・防衛", legacyFamilies: ["term"]),
        .init(id: "work_franchise", label: "作品シリーズ", legacyFamilies: ["work_franchise"]),
        .init(id: "work_manga", label: "漫画作品", legacyFamilies: ["work_manga"]),
        .init(id: "work_anime", label: "アニメ作品", legacyFamilies: ["work_anime"]),
        .init(id: "media_demographic/audience/shonen", label: "少年向け", legacyFamilies: ["character", "work_franchise", "work_manga", "work_anime", "work_film", "work_program", "work_book", "work_game", "work_music", "work_stage", "work_periodical", "work_other"]),
        .init(id: "media_demographic/audience/seinen", label: "青年向け", legacyFamilies: ["character", "work_franchise", "work_manga", "work_anime", "work_film", "work_program", "work_book", "work_game", "work_music", "work_stage", "work_periodical", "work_other"]),
        .init(id: "media_demographic/audience/shojo", label: "少女向け", legacyFamilies: ["character", "work_franchise", "work_manga", "work_anime", "work_film", "work_program", "work_book", "work_game", "work_music", "work_stage", "work_periodical", "work_other"]),
        .init(id: "media_demographic/audience/josei", label: "女性向け（Josei）", legacyFamilies: ["character", "work_franchise", "work_manga", "work_anime", "work_film", "work_program", "work_book", "work_game", "work_music", "work_stage", "work_periodical", "work_other"]),
        .init(id: "media_demographic/audience/kids", label: "子ども向け（Kids）", legacyFamilies: ["character", "work_franchise", "work_manga", "work_anime", "work_film", "work_program", "work_book", "work_game", "work_music", "work_stage", "work_periodical", "work_other"]),
        .init(id: "media_demographic/audience/mixed", label: "複数対象層", legacyFamilies: ["character", "work_franchise", "work_manga", "work_anime", "work_film", "work_program", "work_book", "work_game", "work_music", "work_stage", "work_periodical", "work_other"]),
        .init(id: "media_demographic/audience/unspecified", label: "対象層の指定なし・一般向け", legacyFamilies: ["character", "work_franchise", "work_manga", "work_anime", "work_film", "work_program", "work_book", "work_game", "work_music", "work_stage", "work_periodical", "work_other"]),
        .init(id: "media_demographic/resolution/source_unverified", label: "出典未確認・対象層未確定", legacyFamilies: ["character", "work_franchise", "work_manga", "work_anime", "work_film", "work_program", "work_book", "work_game", "work_music", "work_stage", "work_periodical", "work_other"]),
        .init(id: "work_film", label: "映画作品", legacyFamilies: ["work_film"]),
        .init(id: "work_program", label: "番組", legacyFamilies: ["work_program"]),
        .init(id: "work_book", label: "書籍作品", legacyFamilies: ["work_book"]),
        .init(id: "work_game", label: "ゲーム作品", legacyFamilies: ["work_game"]),
        .init(id: "work_music", label: "音楽作品", legacyFamilies: ["work_music"]),
        .init(id: "work_stage", label: "舞台作品", legacyFamilies: ["work_stage"]),
        .init(id: "work_periodical", label: "定期刊行物", legacyFamilies: ["work_periodical"]),
        .init(id: "work_other", label: "媒体未特定の作品・美術作品", legacyFamilies: ["work_other"]),
        .init(id: "kampo", label: "漢方・生薬", legacyFamilies: ["kampo"]),
        .init(id: "medical", label: "医療", legacyFamilies: ["medical"]),
        .init(id: "surname_origin_unconfirmed", label: "姓・名字（由来未確認）", legacyFamilies: ["person"]),
        .init(id: "given_name_origin_unconfirmed", label: "名・下の名前（由来未確認）", legacyFamilies: ["person"]),
        .init(id: "personal_name_origin_unconfirmed", label: "人名・姓名（由来未確認）", legacyFamilies: ["person"]),
        .init(id: "actor", label: "俳優", legacyFamilies: ["person"]),
        .init(id: "voice_actor", label: "声優", legacyFamilies: ["person"]),
        .init(id: "musician", label: "歌手・音楽家", legacyFamilies: ["person"]),
        .init(id: "idol", label: "アイドル", legacyFamilies: ["person"]),
        .init(id: "comedian", label: "お笑い芸人", legacyFamilies: ["person"]),
        .init(id: "broadcaster", label: "タレント・モデル・放送・報道", legacyFamilies: ["person"]),
        .init(id: "online_creator", label: "配信者・動画投稿者", legacyFamilies: ["person"]),
        .init(id: "sports", label: "スポーツ関係者", legacyFamilies: ["person"]),
        .init(id: "competitive_games", label: "棋士・競技ゲーム選手", legacyFamilies: ["person"]),
        .init(id: "writer", label: "作家・文筆家", legacyFamilies: ["person"]),
        .init(id: "manga_illustration", label: "漫画家・イラストレーター", legacyFamilies: ["person"]),
        .init(id: "film_game_creator", label: "映画・映像・ゲーム制作者", legacyFamilies: ["person"]),
        .init(id: "art_design", label: "美術・写真・建築・デザイン", legacyFamilies: ["person"]),
        .init(id: "performing_arts", label: "舞台・伝統芸能", legacyFamilies: ["person"]),
        .init(id: "science_education", label: "研究・技術・教育", legacyFamilies: ["person"]),
        .init(id: "politics_public", label: "政治・行政・外交・社会運動", legacyFamilies: ["person"]),
        .init(id: "business", label: "実業・経営", legacyFamilies: ["person"]),
        .init(id: "royalty_nobility", label: "皇室・王室・貴族", legacyFamilies: ["person"]),
        .init(id: "other_identified", label: "その他の特定人物", legacyFamilies: ["person"]),
        .init(id: "thought", label: "哲学者・思想家", legacyFamilies: ["person"]),
        .init(id: "surname_origin_japanese", label: "姓・名字（日本由来）", legacyFamilies: ["person"]),
        .init(id: "surname_origin_foreign", label: "姓・名字（海外由来）", legacyFamilies: ["person"]),
        .init(id: "given_name_origin_japanese", label: "名・下の名前（日本由来）", legacyFamilies: ["person"]),
        .init(id: "given_name_origin_foreign", label: "名・下の名前（海外由来）", legacyFamilies: ["person"]),
        .init(id: "personal_name_origin_japanese", label: "人名・姓名（日本由来）", legacyFamilies: ["person"]),
        .init(id: "personal_name_origin_foreign", label: "人名・姓名（海外由来）", legacyFamilies: ["person"]),
    ]
    public static let ids = categories.map(\.id)
    public static let idSet = Set(ids)
    public static func label(for id: String) -> String {
        legacyLabels[id] ?? categories.first(where: { $0.id == id })?.label ?? id
    }
    public static func expanded(legacyMask: UInt32) -> [String] {
        let families = Set(legacyIDs.enumerated().compactMap { legacyMask & (1 << $0.offset) != 0 ? $0.element : nil })
        return categories.filter { !families.isDisjoint(with: $0.legacyFamilies) }.map(\.id)
    }
    /// Absent new selection means an old setting/backup. An explicit empty array means all off.
    public static func selection(defaults: UserDefaults) -> [String] {
        if let values = defaults.stringArray(forKey: selectionKey) { return normalize(values) }
        return expanded(legacyMask: UInt32(defaults.integer(forKey: "categoryMask") & 0x3fff_ffff))
    }
    public static func normalize(_ ids: [String]) -> [String] {
        let selected = Set(ids)
        return self.ids.filter(selected.contains)
    }
    public static func legacyMask(for ids: [String], directory: URL? = nil) -> UInt32 {
        let selected = Set(ids)
        var mask: UInt32 = 0
        for (index, family) in legacyIDs.enumerated() {
            // Shared demographic leaves do not turn on every legacy work dictionary.
            let matches = categories.contains { selected.contains($0.id) && !$0.id.hasPrefix("media_demographic/") && $0.legacyFamilies.contains(family) }
            let exists = directory.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent(family + ".sud").path) } ?? true
            if matches && exists { mask |= 1 << index }
        }
        return mask
    }
    public static func save(_ ids: [String], defaults: UserDefaults) {
        let ids = normalize(ids)
        defaults.set(ids, forKey: selectionKey)
        defaults.set(Int(legacyMask(for: ids)), forKey: "categoryMask")
    }
}
