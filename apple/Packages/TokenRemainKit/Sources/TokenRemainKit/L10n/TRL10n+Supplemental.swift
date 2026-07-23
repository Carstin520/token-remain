import Foundation

extension TRL10n {
    /// Complete translations beyond the English / Simplified Chinese columns kept
    /// in the original catalogue. A compact TSV keeps every key aligned across all
    /// five languages and makes completeness mechanically testable.
    static let supplementalTranslations: [Language: [String: String]] = {
        let languages: [Language] = [.zhHant, .es, .de, .ja, .ko]
        var result = Dictionary(uniqueKeysWithValues: languages.map { ($0, [String: String]()) })

        for rawLine in supplementalSource.split(separator: "\n") {
            let fields = rawLine.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            precondition(fields.count == languages.count + 1, "Malformed localization row: \(rawLine)")
            let key = fields[0]
            for (index, language) in languages.enumerated() {
                precondition(result[language]?[key] == nil, "Duplicate localization key: \(key)")
                result[language]?[key] = fields[index + 1]
            }
        }
        return result
    }()

    // Columns: key, zh-Hant, es, de, ja, ko.
    private static let supplementalSource = """
duration.days_hours_minutes	%1$d 天 %2$d 小時 %3$d 分	%1$d d %2$d h %3$d min	%1$d T %2$d Std %3$d Min	%1$d日 %2$d時間 %3$d分	%1$d일 %2$d시간 %3$d분
duration.days_hours	%1$d 天 %2$d 小時	%1$d d %2$d h	%1$d T %2$d Std	%1$d日 %2$d時間	%1$d일 %2$d시간
duration.hours_minutes	%1$d 小時 %2$d 分	%1$d h %2$d min	%1$d Std %2$d Min	%1$d時間 %2$d分	%1$d시간 %2$d분
duration.minutes	%d 分鐘	%d min	%d Min	%d分	%d분
duration.hours	%d 小時	%d h	%d Std	%d時間	%d시간
duration.days	%d 天	%d d	%d T	%d日	%d일
duration.less_than_minute	不到 1 分鐘	Menos de 1 min	Weniger als 1 Min	1分未満	1분 미만
freshness.just_now	剛剛	Ahora mismo	Gerade eben	たった今	방금
freshness.minutes	%d 分鐘前	Hace %d min	Vor %d Min	%d分前	%d분 전
freshness.hours	%d 小時前	Hace %d h	Vor %d Std	%d時間前	%d시간 전
freshness.days	%d 天前	Hace %d d	Vor %d T	%d日前	%d일 전
reset.in_progress	正在重置	Reiniciando	Wird zurückgesetzt	リセット中	재설정 중
reset.countdown	重置還有 %@	Se reinicia en %@	Zurücksetzung in %@	%@ 後にリセット	%@ 후 재설정
reset.on	%@ 重置	Se reinicia %@	Zurücksetzung %@	%@ にリセット	%@ 재설정
window.suffix	%@視窗	Ventana de %@	%@-Fenster	%@ウィンドウ	%@ 창
risk.headline.low	額度充足	Cuota suficiente	Genügend Kontingent	上限に余裕があります	한도가 충분합니다
risk.headline.medium	額度偏緊	La cuota se está agotando	Kontingent wird knapp	上限が少なくなっています	한도가 빠듯합니다
risk.headline.high	額度即將耗盡	Cuota casi agotada	Kontingent fast aufgebraucht	上限がまもなく尽きます	한도가 거의 소진되었습니다
risk.headline.unknown	暫無額度資料	Sin datos de cuota	Keine Kontingentdaten	上限データがありません	한도 데이터가 없습니다
risk.summary.low	目前節奏可持續到重置。	El ritmo actual dura hasta el reinicio.	Das aktuelle Tempo reicht bis zur Zurücksetzung.	現在のペースならリセットまで持続します。	현재 속도라면 재설정까지 유지됩니다.
risk.summary.medium	剩餘額度有限，請留意使用節奏。	Queda poca cuota; vigila el ritmo.	Das Kontingent ist begrenzt – Tempo beobachten.	残りが少ないため、使用ペースに注意してください。	남은 한도가 적으니 사용 속도를 확인하세요.
risk.summary.high	剩餘額度很低，建議暫緩高消耗工作。	Queda muy poca cuota; evita tareas intensivas.	Sehr wenig Kontingent übrig; intensive Aufgaben pausieren.	残りがごくわずかです。負荷の高い作業は控えてください。	남은 한도가 매우 적습니다. 사용량이 큰 작업은 미루세요.
risk.summary.unknown	尚未讀取到官方額度。	Aún no se ha leído la cuota oficial.	Noch kein offizielles Kontingent gelesen.	公式の上限をまだ取得していません。	공식 한도를 아직 불러오지 못했습니다.
origin.none.title	未連接資料來源	Ninguna fuente conectada	Keine Datenquelle verbunden	データソース未接続	데이터 소스가 연결되지 않음
origin.none.body	iPhone 不會讀取 provider 憑證。請在 Mac 上執行 TokenRemain，讓兩部裝置登入同一個 iCloud 帳號並開啟 iCloud 鑰匙圈；App 會自動連線。你也可以開啟示範模式，查看清楚標示的範例資料。	El iPhone nunca lee las credenciales del proveedor. Ejecuta TokenRemain en el Mac con ambos dispositivos en la misma cuenta de iCloud y el Llavero de iCloud activado; las apps se conectan automáticamente. También puedes usar el modo de demostración.	Das iPhone liest niemals Anbieter-Zugangsdaten. TokenRemain auf dem Mac starten und auf beiden Geräten denselben iCloud-Account mit aktiviertem iCloud-Schlüsselbund verwenden; die Apps verbinden sich automatisch. Alternativ zeigt der Demomodus klar gekennzeichnete Beispieldaten.	iPhone はプロバイダーの認証情報を読み取りません。Mac で TokenRemain を実行し、両方のデバイスで同じ iCloud アカウントと iCloud キーチェーンを有効にすると自動的に接続します。デモモードも利用できます。	iPhone은 제공업체 인증 정보를 읽지 않습니다. Mac에서 TokenRemain을 실행하고 두 기기에서 동일한 iCloud 계정과 iCloud 키체인을 사용하면 앱이 자동으로 연결됩니다. 데모 모드도 사용할 수 있습니다.
origin.demo.status	所有資料來源正常	Todas las fuentes están correctas	Alle Quellen in Ordnung	すべてのソースは正常です	모든 소스가 정상입니다
origin.none.status	未連接資料來源	Sin fuente de datos	Keine Datenquelle	データソースなし	데이터 소스 없음
origin.macsync.status	來自 Mac 的加密快照	Captura cifrada del Mac	Verschlüsselter Snapshot vom Mac	Mac からの暗号化スナップショット	Mac의 암호화된 스냅샷
origin.macsync.freshness	來自 Mac · %@	Del Mac · %@	Vom Mac · %@	Mac から · %@	Mac에서 · %@
origin.macsync.expired	Mac 資料已過期	Los datos del Mac han caducado	Mac-Daten sind abgelaufen	Mac のデータは期限切れです	Mac 데이터가 만료되었습니다
demo.chip	示範	DEMO	DEMO	デモ	데모
demo.a11y	示範資料	Datos de demostración	Demodaten	デモデータ	데모 데이터
privacy.statement	預設只在本機處理。Mac 同步只會將白名單額度快照寫入應用程式層加密的 iCloud 私人資料庫；每日 Token／費用歷史需在 Mac 上另行授權，provider 憑證永不會上傳。	El procesamiento es local por defecto. La sincronización del Mac solo escribe una captura de cuota permitida en tu base de datos privada de iCloud, cifrada por la app. El historial diario de tokens y costes requiere autorización aparte en el Mac; las credenciales nunca se suben.	Die Verarbeitung erfolgt standardmäßig lokal. Die Mac-Synchronisierung schreibt nur einen freigegebenen Kontingent-Snapshot in die zusätzlich verschlüsselte private iCloud-Datenbank. Der tägliche Token-/Kostenverlauf muss auf dem Mac separat erlaubt werden; Anbieter-Zugangsdaten werden nie hochgeladen.	処理はデフォルトでローカルです。Mac 同期では許可された上限スナップショットだけをアプリ層で暗号化した iCloud プライベートデータベースに保存します。日別のトークン／費用履歴は Mac で別途許可が必要で、認証情報はアップロードされません。	기본적으로 기기에서만 처리합니다. Mac 동기화는 허용 목록의 한도 스냅샷만 앱 계층으로 암호화해 iCloud 비공개 데이터베이스에 저장합니다. 일별 토큰/비용 기록은 Mac에서 별도 승인이 필요하며 제공업체 인증 정보는 업로드되지 않습니다.
tab.overview	概覽	Resumen	Übersicht	概要	개요
tab.limits	額度	Límites	Limits	上限	한도
tab.trends	趨勢	Tendencias	Trends	推移	추세
tab.settings	設定	Ajustes	Einstellungen	設定	설정
overview.risk.caption	目前額度風險	Riesgo de cuota actual	Aktuelles Kontingentrisiko	現在の上限リスク	현재 한도 위험
overview.min_remaining	最低剩餘	Mínimo restante	Niedrigster Restwert	最小残量	최소 잔여량
overview.pace.ok	可持續到重置	Dura hasta el reinicio	Reicht bis zur Zurücksetzung	リセットまで持続	재설정까지 유지
overview.pace.runout	預計 %@ 後用盡	Se agota en %@	Aufgebraucht in %@	%@ 後に尽きる見込み	%@ 후 소진 예상
overview.reset.card	重置還有	Se reinicia en	Zurücksetzung in	リセットまで	재설정까지
overview.trend.card	7 天趨勢	Tendencia de 7 días	7-Tage-Trend	7日間の推移	7일 추세
overview.trend.empty	暫無每日用量歷史	Aún no hay historial diario	Noch kein täglicher Verlauf	日別使用履歴はまだありません	일별 사용 기록이 아직 없습니다
overview.cta	查看最緊張的視窗	Ver ventana más ajustada	Knappstes Fenster anzeigen	最も厳しいウィンドウを表示	가장 빠듯한 창 보기
overview.provider.hint	點一下查看此資料來源的視窗詳情	Toca para ver las ventanas de esta fuente	Tippen, um die Fenster dieser Quelle anzuzeigen	タップしてこのソースのウィンドウ詳細を表示	탭하여 이 소스의 창 세부 정보 보기
overview.today.today	今日	Hoy	Heute	今日	오늘
overview.today.yesterday	昨日	Ayer	Gestern	昨日	어제
overview.today.recent	近 %d 天	Últimos %d días	Letzte %d Tage	直近%d日	최근 %d일
overview.today.trend	用量趨勢	Tendencia de uso	Nutzungstrend	使用量の推移	사용 추이
overview.today.cost.a11y	今日用量，預估成本 %@ 美元	Uso de hoy, coste estimado de %@ dólares	Heutige Nutzung, geschätzte Kosten %@ US-Dollar	今日の使用量、推定コスト %@ 米ドル	오늘 사용량, 예상 비용 %@달러
overview.widget.manage	管理概覽元件	Gestionar widgets del resumen	Übersichts-Widgets verwalten	概要ウィジェットを管理	개요 위젯 관리
overview.widget.visible	顯示中	Visible	Sichtbar	表示中	표시 중
overview.widget.add	新增元件	Añadir widget	Widget hinzufügen	ウィジェットを追加	위젯 추가
overview.widget.all.visible	所有元件均已顯示	Se muestran todos los widgets	Alle Widgets werden angezeigt	すべてのウィジェットを表示中	모든 위젯이 표시 중입니다
overview.widget.hide	隱藏元件	Ocultar widget	Widget ausblenden	ウィジェットを非表示	위젯 숨기기
overview.widget.move	移動元件	Mover widget	Widget verschieben	ウィジェットを移動	위젯 이동
overview.widget.move.up	上移	Subir	Nach oben	上へ移動	위로 이동
overview.widget.move.down	下移	Bajar	Nach unten	下へ移動	아래로 이동
overview.widget.options	元件選項	Opciones del widget	Widget-Optionen	ウィジェットのオプション	위젯 옵션
overview.widget.expand	展開視窗	Expandir ventanas	Fenster ausklappen	ウィンドウを展開	창 펼치기
overview.widget.collapse	收合視窗	Contraer ventanas	Fenster einklappen	ウィンドウを折りたたむ	창 접기
overview.feed.title	精選 X 動態	Publicaciones seleccionadas de X	Kuratierte X-Posts	厳選 X ポスト	선별된 X 게시물
overview.feed.empty	正在等待廣播來源發布第一則 X 動態。	Esperando la primera publicación de X del canal.	Warten auf den ersten X-Post des Broadcast-Feeds.	配信元から最初の X ポストを待っています。	방송 피드의 첫 X 게시물을 기다리는 중입니다.
overview.feed.freshness	廣播更新於 %@	Canal actualizado %@	Broadcast aktualisiert %@	配信更新 %@	방송 업데이트 %@
overview.feed.open.hint	在 X 開啟這則公開動態	Abrir esta publicación pública en X	Diesen öffentlichen Post auf X öffnen	この公開ポストを X で開く	이 공개 게시물을 X에서 열기
limits.window.caption	官方額度視窗	Ventana de cuota oficial	Offizielles Kontingentfenster	公式上限ウィンドウ	공식 한도 창
limits.freshness	官方資料更新於 %@	Datos oficiales actualizados %@	Offizielle Daten aktualisiert %@	公式データ更新 %@	공식 데이터 업데이트 %@
limits.pace.expected	預算用量	Uso previsto	Geplante Nutzung	予定使用量	예산 사용량
limits.pace.actual	實際用量	Uso real	Tatsächliche Nutzung	実際の使用量	실제 사용량
limits.pace.delta	偏差	Diferencia	Abweichung	差分	차이
limits.pace.status.ontrack	符合預算	Dentro del presupuesto	Im Soll	予算どおり	예산 내
limits.pace.status.reserve	有餘裕	Con margen	Reserve	余裕あり	여유 있음
limits.pace.status.deficit	超出預算	Por encima del presupuesto	Über dem Budget	予算超過	예산 초과
limits.pace.projected	按目前節奏預計 %@ 後用盡	Al ritmo actual, se agotará en %@	Beim aktuellen Tempo voraussichtlich in %@ aufgebraucht	現在のペースでは %@ 後に尽きる見込み	현재 속도라면 %@ 후 소진 예상
limits.pace.unavailable	視窗剛開始，暫不預測使用節奏	La ventana acaba de empezar; aún no hay estimación	Fenster gerade gestartet – noch keine Schätzung	ウィンドウ開始直後のため予測はまだありません	창이 막 시작되어 아직 예상할 수 없습니다
limits.reset.section	官方重置時間	Hora de reinicio oficial	Offizielle Zurücksetzungszeit	公式リセット時刻	공식 재설정 시간
limits.reset.unknown	重置時間未知	Hora de reinicio desconocida	Zurücksetzungszeit unbekannt	リセット時刻不明	재설정 시간 알 수 없음
limits.empty	沒有可顯示的額度視窗。	No hay ventanas de cuota que mostrar.	Keine Kontingentfenster vorhanden.	表示できる上限ウィンドウがありません。	표시할 한도 창이 없습니다.
trends.title.usage	每日用量趨勢	Tendencia de uso diario	Täglicher Nutzungstrend	日別使用量の推移	일별 사용 추이
trends.subtitle.usage	Claude + Codex 堆疊 · 來自 Mac 本機 ccusage	Claude + Codex apilados · ccusage local del Mac	Claude + Codex gestapelt · lokales Mac-ccusage	Claude + Codex の積み上げ · Mac のローカル ccusage	Claude + Codex 누적 · Mac 로컬 ccusage
trends.range	範圍	Periodo	Zeitraum	範囲	범위
trends.metric	指標	Métrica	Metrik	指標	지표
trends.metric.tokens	Tokens	Tokens	Tokens	トークン	토큰
trends.metric.cost	費用	Coste	Kosten	コスト	비용
trends.readout.latest	最新一天	Último día	Letzter Tag	最新日	최근 날짜
trends.readout.selected	已選	Seleccionado	Ausgewählt	選択中	선택됨
trends.readout.a11y	%1$@，Claude %2$@，Codex %3$@	%1$@, Claude %2$@, Codex %3$@	%1$@, Claude %2$@, Codex %3$@	%1$@、Claude %2$@、Codex %3$@	%1$@, Claude %2$@, Codex %3$@
trends.value.tokens.a11y	%@ Tokens	%@ tokens	%@ Tokens	%@トークン	%@ 토큰
trends.value.cost.a11y	預估費用 %@ 美元	Coste estimado de %@ dólares	Geschätzte Kosten %@ US-Dollar	推定コスト %@ 米ドル	예상 비용 %@달러
trends.totals.title	近 %d 天合計	Total de %d días	%d-Tage-Gesamtwert	%d日間の合計	%d일 합계
trends.totals.combined	合計	Total	Gesamt	合計	합계
trends.empty.title	每日歷史累積中	Acumulando historial diario	Täglicher Verlauf wird aufgebaut	日別履歴を蓄積中	일별 기록 수집 중
trends.meta.days	已同步 %d 天真實歷史	%d días de historial real sincronizados	%d Tage echter Verlauf synchronisiert	実データを%d日分同期済み	실제 기록 %d일 동기화됨
trends.meta.captured	Mac 最近擷取 %@	Última captura en el Mac %@	Zuletzt auf dem Mac erfasst %@	Mac の最終取得 %@	Mac에서 마지막 수집 %@
trends.chart.a11y	%d 天堆疊長條圖，指標 %@	Gráfico de barras apiladas de %d días, métrica %@	Gestapeltes Balkendiagramm für %d Tage, Metrik %@	%d日間の積み上げ棒グラフ、指標 %@	%d일 누적 막대 차트, 지표 %@
trends.privacy	歷史只包含 Claude／Codex 的每日 Token 與預估費用；不包含帳號、提示詞、專案、對話或逐次請求明細。	El historial solo contiene tokens diarios de Claude/Codex y costes estimados; no incluye cuentas, instrucciones, proyectos, sesiones ni detalles por solicitud.	Der Verlauf enthält nur tägliche Claude-/Codex-Token und geschätzte Kosten; keine Accounts, Prompts, Projekte, Sitzungen oder Anfragedetails.	履歴には Claude／Codex の日別トークンと推定コストだけが含まれ、アカウント、プロンプト、プロジェクト、セッション、リクエスト単位の詳細は含まれません。	기록에는 Claude/Codex의 일별 토큰과 예상 비용만 포함되며 계정, 프롬프트, 프로젝트, 세션, 요청별 세부 정보는 포함되지 않습니다.
trends.title.min	最低剩餘（按天）	Mínimo restante (diario)	Niedrigster Restwert (täglich)	最小残量（日別）	최소 잔여량(일별)
trends.title.provider	各資料來源剩餘	Restante por fuente	Restwert nach Quelle	ソース別残量	소스별 잔여량
trends.meta.points	記錄點數 %d	%d puntos registrados	%d aufgezeichnete Punkte	記録点数 %d	기록 지점 %d개
trends.meta.earliest	最早記錄 %@	Primer registro %@	Frühester Eintrag %@	最初の記録 %@	가장 이른 기록 %@
trends.empty	需要 Mac 至少累積兩天 ccusage 歷史，並在桌面版中另行開啟「同步每日 Token／費用歷史」。這裡不會用額度快照虛構曲線。	Se necesitan al menos dos días de historial de ccusage del Mac y activar por separado «Sincronizar historial diario de tokens/costes» en la app de escritorio. Las capturas de cuota nunca se convierten en una curva inventada.	Mindestens zwei Tage Mac-ccusage-Verlauf sind nötig. Außerdem muss „Täglichen Token-/Kostenverlauf synchronisieren“ auf dem Desktop separat aktiviert sein. Kontingent-Snapshots werden nie zu einer erfundenen Kurve.	Mac の ccusage 履歴が2日分以上必要で、デスクトップ側で「日別トークン／費用履歴を同期」を別途有効にする必要があります。上限スナップショットから架空のグラフを作ることはありません。	Mac ccusage 기록이 최소 2일 필요하며 데스크톱에서 ‘일별 토큰/비용 기록 동기화’를 별도로 켜야 합니다. 한도 스냅샷으로 임의의 곡선을 만들지 않습니다.
settings.section.source	資料來源	Fuente de datos	Datenquelle	データソース	데이터 소스
settings.origin.row	目前來源	Origen actual	Aktuelle Quelle	現在のソース	현재 소스
settings.demo.toggle	示範模式	Modo de demostración	Demomodus	デモモード	데모 모드
settings.macsync.toggle	從 Mac 安全同步	Sincronización segura desde el Mac	Sicher vom Mac synchronisieren	Mac から安全に同期	Mac에서 보안 동기화
settings.macsync.refresh	立即從 iCloud 擷取	Obtener de iCloud ahora	Jetzt aus iCloud abrufen	iCloud から今すぐ取得	지금 iCloud에서 가져오기
settings.macsync.retry	立即重試	Reintentar ahora	Jetzt erneut versuchen	今すぐ再試行	지금 다시 시도
settings.macsync.confirm	確認改用這部 Mac	Confirmar este Mac como fuente	Diesen Mac als Quelle bestätigen	この Mac をソースとして確認	이 Mac을 소스로 확인
settings.sync.automatic	自動同步	Sincronización automática	Automatische Synchronisierung	自動同期	자동 동기화
settings.sync.automatic_on	已開啟	Activada	Ein	オン	켜짐
settings.sync.automatic_detail	首次啟動時自動檢查；連線期間快速重試，連線後每 45 秒檢查。進入背景後由 iCloud 變更喚醒。	Realiza una autocomprobación al iniciarse por primera vez, reintenta rápidamente durante la conexión y después comprueba cada 45 segundos. Los cambios de iCloud la activan en segundo plano.	Führt beim ersten Start eine Selbstprüfung durch, versucht die Verbindung zunächst schnell erneut und prüft danach alle 45 Sekunden. iCloud-Änderungen wecken die App im Hintergrund.	初回起動時に自動診断し、接続中は短い間隔で再試行、接続後は45秒ごとに確認します。バックグラウンドでは iCloud の変更で起動します。	처음 실행할 때 자동 점검하고 연결 중에는 빠르게 재시도한 뒤 연결되면 45초마다 확인합니다. 백그라운드에서는 iCloud 변경으로 깨어납니다.
settings.sync.health.icloud	iCloud	iCloud	iCloud	iCloud	iCloud
settings.sync.health.key	同步金鑰	Clave de sincronización	Sync-Schlüssel	同期キー	동기화 키
settings.sync.health.snapshot	Mac 快照	Captura del Mac	Mac-Snapshot	Mac スナップショット	Mac 스냅샷
settings.sync.health.available	可用	Disponible	Verfügbar	利用可能	사용 가능
settings.sync.health.unavailable	無法使用	No disponible	Nicht verfügbar	利用不可	사용 불가
settings.sync.health.ready	已就緒	Lista	Bereit	準備完了	준비됨
settings.sync.health.waiting	正在等待	Esperando	Warten	待機中	대기 중
settings.sync.health.found	已找到	Encontrada	Gefunden	検出済み	찾음
settings.sync.health.not_found	尚未找到	Aún no encontrada	Noch nicht gefunden	未検出	아직 찾지 못함
settings.sync.health.pending	檢查中	Comprobando	Wird geprüft	確認中	확인 중
settings.sync.last_check	最近自動檢查	Última comprobación automática	Letzte automatische Prüfung	前回の自動確認	최근 자동 확인
settings.sync.provider_captured	Provider 擷取	Captura del proveedor	Anbieter erfasst	プロバイダー取得	제공업체 수집
settings.sync.phone_rendered	手機呈現	Mostrado en el teléfono	Auf dem iPhone angezeigt	スマートフォン表示	휴대폰 표시
settings.sync.latency	前景延遲 · p50 %.0f 秒 · p95 %.0f 秒 · 最大 %.0f 秒 · n=%d	Latencia en primer plano · p50 %.0fs · p95 %.0fs · máx. %.0fs · n=%d	Vordergrundlatenz · p50 %.0fs · p95 %.0fs · max. %.0fs · n=%d	フォアグラウンド遅延 · p50 %.0f秒 · p95 %.0f秒 · 最大 %.0f秒 · n=%d	포그라운드 지연 · p50 %.0f초 · p95 %.0f초 · 최대 %.0f초 · n=%d
settings.sync.pulling	正在安全擷取…	Obteniendo de forma segura…	Sicherer Abruf…	安全に取得中…	안전하게 가져오는 중…
settings.sync.waiting_mac	等待 Mac 上傳第一份快照	Esperando la primera captura del Mac	Warten auf den ersten Mac-Snapshot	Mac の最初のスナップショットを待機中	Mac의 첫 스냅샷을 기다리는 중
settings.sync.waiting_key	等待 iCloud 鑰匙圈同步金鑰	Esperando la clave del Llavero de iCloud	Warten auf den iCloud-Schlüsselbundschlüssel	iCloud キーチェーンの同期キーを待機中	iCloud 키체인 동기화 키를 기다리는 중
settings.sync.synced	已同步 · %@	Sincronizado · %@	Synchronisiert · %@	同期済み · %@	동기화됨 · %@
settings.sync.latest_snapshot	最新快照 · %@	Última captura · %@	Neuester Snapshot · %@	最新スナップショット · %@	최신 스냅샷 · %@
settings.sync.source_change	偵測到新的 Mac 資料來源，需要確認	Una nueva fuente de Mac requiere confirmación	Eine neue Mac-Quelle muss bestätigt werden	新しい Mac ソースの確認が必要です	새 Mac 소스를 확인해야 합니다
settings.sync.error.account	iCloud 帳號無法使用或未授權	La cuenta de iCloud no está disponible o autorizada	iCloud-Account nicht verfügbar oder nicht autorisiert	iCloud アカウントを利用できないか、許可されていません	iCloud 계정을 사용할 수 없거나 승인되지 않았습니다
settings.sync.error.temporary	iCloud 暫時無法使用，請稍後再試	iCloud no está disponible temporalmente; inténtalo más tarde	iCloud ist vorübergehend nicht verfügbar; später erneut versuchen	iCloud は一時的に利用できません。後でもう一度お試しください	iCloud를 일시적으로 사용할 수 없습니다. 나중에 다시 시도하세요
settings.sync.error.remote	等待 Mac 上傳快照	Esperando una captura del Mac	Warten auf einen Mac-Snapshot	Mac のスナップショットを待機中	Mac 스냅샷을 기다리는 중
settings.sync.error.key	等待 iCloud 鑰匙圈同步金鑰	Esperando la clave del Llavero de iCloud	Warten auf den iCloud-Schlüsselbundschlüssel	iCloud キーチェーンの同期キーを待機中	iCloud 키체인 동기화 키를 기다리는 중
settings.sync.error.security	遠端快照未通過安全驗證，已保留舊資料	La captura remota no superó la validación de seguridad; se conservaron los datos anteriores	Remote-Snapshot hat die Sicherheitsprüfung nicht bestanden; alte Daten wurden beibehalten	リモートスナップショットの安全性を確認できなかったため、以前のデータを保持しました	원격 스냅샷이 보안 검증을 통과하지 못해 기존 데이터를 유지했습니다
sync.guidance.mac_message	請在 Mac 上開啟 TokenRemain。Mac 會自動檢查 iCloud、建立同步金鑰並上傳第一份加密快照，無需手動開啟同步。	Abre TokenRemain en el Mac. Comprobará iCloud, creará la clave y subirá automáticamente la primera captura cifrada.	TokenRemain auf dem Mac öffnen. Die App prüft iCloud, erstellt den Sync-Schlüssel und lädt den ersten verschlüsselten Snapshot automatisch hoch.	Mac で TokenRemain を開いてください。iCloud の確認、同期キーの作成、最初の暗号化スナップショットのアップロードが自動で行われます。	Mac에서 TokenRemain을 여세요. iCloud 확인, 동기화 키 생성, 첫 암호화 스냅샷 업로드가 자동으로 진행됩니다.
sync.guidance.icloud_message	請確認已登入 iCloud 並開啟 iCloud Drive。路徑：設定 > 你的名字 > iCloud。恢復後 TokenRemain 會自動重試。	Confirma que has iniciado sesión en iCloud y que iCloud Drive está activado: Ajustes > tu nombre > iCloud. TokenRemain reintentará automáticamente.	Prüfen, ob du bei iCloud angemeldet bist und iCloud Drive aktiviert ist: Einstellungen > dein Name > iCloud. TokenRemain versucht es automatisch erneut.	iCloud にサインインし、iCloud Drive がオンであることを確認してください：設定 > 自分の名前 > iCloud。復旧後は自動的に再試行します。	iCloud에 로그인되어 있고 iCloud Drive가 켜져 있는지 확인하세요: 설정 > 사용자 이름 > iCloud. 복구되면 자동으로 다시 시도합니다.
sync.guidance.keychain_message	已找到 Mac 快照，但同步金鑰仍未到達。請確認兩部裝置使用同一 Apple 帳號，並前往「設定 > 你的名字 > iCloud > 密碼與鑰匙圈」開啟同步。	Se encontró la captura del Mac, pero la clave aún no llegó. Confirma que ambos dispositivos usan la misma cuenta de Apple y activa Contraseñas y Llavero en Ajustes > tu nombre > iCloud.	Der Mac-Snapshot wurde gefunden, aber der Schlüssel ist noch nicht angekommen. Auf beiden Geräten denselben Apple Account verwenden und Passwörter & Schlüsselbund unter Einstellungen > dein Name > iCloud aktivieren.	Mac のスナップショットは見つかりましたが、同期キーがまだ届いていません。両方で同じ Apple Account を使い、「設定 > 自分の名前 > iCloud > パスワードとキーチェーン」をオンにしてください。	Mac 스냅샷은 찾았지만 동기화 키가 아직 도착하지 않았습니다. 두 기기에서 같은 Apple 계정을 사용하고 설정 > 사용자 이름 > iCloud > 암호 및 키체인을 켜세요.
sync.guidance.review	診斷詳情	Revisar estado	Status prüfen	診断を確認	진단 보기
sync.guidance.later	稍後	Más tarde	Später	あとで	나중에
settings.demo.footer	Mac 同步使用 iCloud 私人資料庫與應用程式層加密；每日 Token／費用歷史需在 Mac 上另行授權，provider 憑證永不會上傳。示範模式只使用固定的範例資料。	La sincronización del Mac usa tu base de datos privada de iCloud y cifrado de la app. El historial diario de tokens y costes requiere autorización aparte en el Mac; las credenciales nunca se suben. El modo de demostración solo usa datos de ejemplo deterministas.	Die Mac-Synchronisierung nutzt die private iCloud-Datenbank plus App-Verschlüsselung. Der tägliche Token-/Kostenverlauf muss auf dem Mac separat erlaubt werden; Anbieter-Zugangsdaten werden nie hochgeladen. Der Demomodus nutzt nur feste Beispieldaten.	Mac 同期は iCloud プライベートデータベースとアプリ層の暗号化を使用します。日別のトークン／費用履歴は Mac で別途許可が必要で、認証情報はアップロードされません。デモモードは固定のサンプルデータだけを使用します。	Mac 동기화는 iCloud 비공개 데이터베이스와 앱 계층 암호화를 사용합니다. 일별 토큰/비용 기록은 Mac에서 별도 승인이 필요하며 제공업체 인증 정보는 업로드되지 않습니다. 데모 모드는 고정된 예시 데이터만 사용합니다.
settings.scenario	示範情境	Escenario de demostración	Demoszenario	デモシナリオ	데모 시나리오
settings.section.liveactivity	即時動態	Actividad en directo	Live-Aktivität	ライブアクティビティ	실시간 현황
settings.liveactivity.start	開始即時動態	Iniciar Actividad en directo	Live-Aktivität starten	ライブアクティビティを開始	실시간 현황 시작
settings.liveactivity.stop	停止即時動態	Detener Actividad en directo	Live-Aktivität stoppen	ライブアクティビティを停止	실시간 현황 중지
settings.liveactivity.active	執行中	En curso	Aktiv	実行中	실행 중
settings.liveactivity.inactive	未執行	Inactiva	Nicht aktiv	停止中	실행 안 함
settings.liveactivity.denied	系統已關閉此 App 的即時動態權限，請在 iOS「設定」中開啟。	Las Actividades en directo están desactivadas para esta app en Ajustes de iOS.	Live-Aktivitäten sind für diese App in den iOS-Einstellungen deaktiviert.	iOS の設定でこのアプリのライブアクティビティが無効になっています。	iOS 설정에서 이 앱의 실시간 현황이 비활성화되어 있습니다.
settings.liveactivity.needsdemo	即時動態只顯示示範資料，請先開啟示範模式。	La Actividad en directo solo muestra datos de demostración; activa primero el modo de demostración.	Die Live-Aktivität zeigt nur Demodaten; zuerst den Demomodus aktivieren.	ライブアクティビティにはデモデータだけが表示されます。先にデモモードをオンにしてください。	실시간 현황은 데모 데이터만 표시합니다. 먼저 데모 모드를 켜세요.
settings.liveactivity.needssource	連接 Mac 同步或開啟示範模式後才能開始。	Conecta la sincronización del Mac o activa el modo de demostración para empezar.	Zum Starten Mac-Synchronisierung verbinden oder Demomodus aktivieren.	Mac 同期に接続するかデモモードをオンにすると開始できます。	Mac 동기화를 연결하거나 데모 모드를 켜야 시작할 수 있습니다.
settings.section.widgets	小工具	Widgets	Widgets	ウィジェット	위젯
settings.widgets.home	長按主畫面空白處 › 編輯 › 加入小工具 › TokenRemain	Mantén pulsada la pantalla de inicio › Editar › Añadir widget › TokenRemain	Home-Bildschirm gedrückt halten › Bearbeiten › Widget hinzufügen › TokenRemain	ホーム画面を長押し › 編集 › ウィジェットを追加 › TokenRemain	홈 화면 길게 누르기 › 편집 › 위젯 추가 › TokenRemain
settings.widgets.lock	鎖定畫面 › 自訂 › 加入小工具 › TokenRemain	Pantalla de bloqueo › Personalizar › Añadir widgets › TokenRemain	Sperrbildschirm › Anpassen › Widgets hinzufügen › TokenRemain	ロック画面 › カスタマイズ › ウィジェットを追加 › TokenRemain	잠금 화면 › 사용자화 › 위젯 추가 › TokenRemain
settings.widgets.control	設定 › 動作按鈕 › 控制項目 › 重新整理額度	Ajustes › Botón de acción › Controles › Actualizar cuota	Einstellungen › Aktionstaste › Steuerelemente › Kontingent aktualisieren	設定 › アクションボタン › コントロール › 上限を更新	설정 › 동작 버튼 › 제어 항목 › 한도 새로 고침
settings.section.watch	Apple Watch	Apple Watch	Apple Watch	Apple Watch	Apple Watch
settings.watch.paired	已配對	Enlazado	Gekoppelt	ペアリング済み	페어링됨
settings.watch.notpaired	未配對	No enlazado	Nicht gekoppelt	未ペアリング	페어링 안 됨
settings.watch.installed	已安裝 Watch App	App del Watch instalada	Watch-App installiert	Watch アプリをインストール済み	Watch 앱 설치됨
settings.watch.notinstalled	未安裝 Watch App	App del Watch no instalada	Watch-App nicht installiert	Watch アプリ未インストール	Watch 앱 설치 안 됨
settings.watch.lastsync	上次同步 %@	Última sincronización %@	Letzte Synchronisierung %@	最終同期 %@	마지막 동기화 %@
settings.watch.neversync	尚未同步	Nunca sincronizado	Noch nie synchronisiert	未同期	동기화한 적 없음
settings.watch.unsupported	此裝置無法使用 WatchConnectivity	WatchConnectivity no está disponible en este dispositivo	WatchConnectivity ist auf diesem Gerät nicht verfügbar	このデバイスでは WatchConnectivity を利用できません	이 기기에서는 WatchConnectivity를 사용할 수 없습니다
settings.section.about	關於	Acerca de	Über	情報	정보
settings.version	版本	Versión	Version	バージョン	버전
intent.refresh.title	重新整理額度	Actualizar cuota	Kontingent aktualisieren	上限を更新	한도 새로 고침
intent.refresh.done	已重新整理 · 最低 %@	Actualizado · mínimo %@	Aktualisiert · niedrigster Wert %@	更新済み · 最小 %@	새로 고침 완료 · 최소 %@
intent.refresh.none	未連接資料來源	Ninguna fuente conectada	Keine Datenquelle verbunden	データソース未接続	데이터 소스가 연결되지 않음
intent.open.title	查看 TokenRemain	Abrir TokenRemain	TokenRemain öffnen	TokenRemain を開く	TokenRemain 열기
intent.startla.title	開始即時動態	Iniciar Actividad en directo	Live-Aktivität starten	ライブアクティビティを開始	실시간 현황 시작
intent.stopla.title	停止即時動態	Detener Actividad en directo	Live-Aktivität stoppen	ライブアクティビティを停止	실시간 현황 중지
intent.startla.done	即時動態已開始	Actividad en directo iniciada	Live-Aktivität gestartet	ライブアクティビティを開始しました	실시간 현황을 시작했습니다
intent.stopla.done	即時動態已停止	Actividad en directo detenida	Live-Aktivität beendet	ライブアクティビティを停止しました	실시간 현황을 중지했습니다
liveactivity.indicator	即時	EN VIVO	LIVE	ライブ	실시간
liveactivity.stale	資料未更新	Datos sin actualizar	Daten nicht aktualisiert	データ未更新	데이터가 업데이트되지 않음
liveactivity.refresh	重新整理	Actualizar	Aktualisieren	更新	새로 고침
risk.short.low	低	BAJO	NIEDRIG	低	낮음
risk.short.medium	中	MEDIO	MITTEL	中	보통
risk.short.high	高	ALTO	HOCH	高	높음
risk.short.unknown	—	—	—	—	—
pace.short.ok	可持續到重置	Dura hasta el reinicio	Reicht bis zur Zurücksetzung	リセットまで持続	재설정까지 유지
pace.short.early	可能提前用盡	Puede agotarse antes	Könnte zu früh aufgebraucht sein	早期に尽きる可能性あり	일찍 소진될 수 있음
today.title	今日用量	Uso de hoy	Heutige Nutzung	今日の使用量	오늘 사용량
today.tokens	Tokens	Tokens	Tokens	トークン	토큰
today.cost	預估成本	Coste est.	Gesch. Kosten	推定コスト	예상 비용
today.empty	暫無本機統計	Aún no hay uso local	Noch keine lokale Nutzung	ローカル使用量はまだありません	로컬 사용량이 아직 없습니다
today.source.demo	示範 · 資料留在本機	Demo · los datos permanecen en el dispositivo	Demo · Daten bleiben auf dem Gerät	デモ · データはデバイス内に保持	데모 · 데이터는 기기에 보관
watch.provenance	來自 iPhone · %@	Del iPhone · %@	Vom iPhone · %@	iPhone から · %@	iPhone에서 · %@
watch.plan	%@ 方案	Plan %@	%@-Abo	%@プラン	%@ 요금제
watch.page.overview	概覽	Resumen	Übersicht	概要	개요
watch.waiting	等待 iPhone 同步	Esperando la sincronización del iPhone	Warten auf iPhone-Synchronisierung	iPhone の同期を待機中	iPhone 동기화를 기다리는 중
watch.waiting.body	在 iPhone 上開啟 TokenRemain，即可同步最新快照。	Abre TokenRemain en el iPhone para sincronizar la última captura.	TokenRemain auf dem iPhone öffnen, um den neuesten Snapshot zu synchronisieren.	iPhone で TokenRemain を開くと最新のスナップショットが同期されます。	iPhone에서 TokenRemain을 열어 최신 스냅샷을 동기화하세요.
robot.100	額度充足，興奮	Cuota abundante: eufórico	Genügend Kontingent – begeistert	上限に余裕あり・興奮	한도 충분 · 신남
robot.90	額度充足，開心	Cuota abundante: feliz	Genügend Kontingent – glücklich	上限に余裕あり・笑顔	한도 충분 · 행복
robot.80	額度健康，精神	Cuota saludable: animado	Gesundes Kontingent – munter	上限は良好・元気	한도 양호 · 활기참
robot.70	額度健康，平穩	Cuota saludable: tranquilo	Gesundes Kontingent – ruhig	上限は良好・安定	한도 양호 · 차분
robot.60	額度適中，專注	Cuota moderada: concentrado	Mittleres Kontingent – konzentriert	上限は中程度・集中	한도 보통 · 집중
robot.50	額度過半，平淡	Más de la mitad usada: neutral	Über die Hälfte verbraucht – neutral	半分以上使用・ニュートラル	절반 이상 사용 · 보통
robot.40	額度偏低，擔憂	Cuota baja: preocupado	Niedriges Kontingent – besorgt	上限が少ない・心配	한도 낮음 · 걱정
robot.30	額度較低，緊張	Cuota más baja: tenso	Sehr niedriges Kontingent – angespannt	上限がさらに少ない・緊張	한도 매우 낮음 · 긴장
robot.20	額度很低，暈眩	Cuota muy baja: mareado	Sehr wenig Kontingent – benommen	上限がごく少ない・めまい	한도 매우 낮음 · 어지러움
robot.10	額度即將耗盡，焦慮	Cuota casi agotada: ansioso	Fast aufgebraucht – nervös	まもなく上限・不安	한도 거의 소진 · 불안
robot.0	額度已耗盡	Cuota agotada	Kontingent aufgebraucht	上限を使い切りました	한도 소진
robot.a11y.waiting	TokenRemain，等待額度資料	TokenRemain, esperando datos de cuota	TokenRemain, wartet auf Kontingentdaten	TokenRemain、上限データを待機中	TokenRemain, 한도 데이터 대기 중
robot.a11y.value	TokenRemain，剩餘 %1$d%%，%2$@	TokenRemain, %1$d%% restante, %2$@	TokenRemain, %1$d%% übrig, %2$@	TokenRemain、残り%1$d%%、%2$@	TokenRemain, %1$d%% 남음, %2$@
mark.ai_usage	AI 用量	Uso de IA	KI-Nutzung	AI 使用量	AI 사용량
scenario.concept	設計稿	Concepto	Konzept	コンセプト	콘셉트
scenario.deficit	超出預算節奏	Ritmo por encima del presupuesto	Über dem Budget	予算超過ペース	예산 초과 속도
scenario.critical	額度告急	Crítico	Kritisch	残量わずか	한도 위험
scenario.freshreset	剛剛重置	Recién reiniciado	Frisch zurückgesetzt	リセット直後	방금 재설정
gallery.corner.actual	實際角標尺寸	Tamaño real de la esquina	Tatsächliche Eckgröße	実際のコーナーサイズ	실제 모서리 크기
widget.name.quota	TokenRemain · 額度	TokenRemain · Cuota	TokenRemain · Kontingent	TokenRemain · 上限	TokenRemain · 한도
widget.name.percent	TokenRemain · 百分比	TokenRemain · %	TokenRemain · %	TokenRemain · %	TokenRemain · %
widget.name.reset	TokenRemain · 重置	TokenRemain · Reinicio	TokenRemain · Zurücksetzung	TokenRemain · リセット	TokenRemain · 재설정
widget.name.rings	TokenRemain · 剩餘圓環	TokenRemain · Anillos restantes	TokenRemain · Restringe	TokenRemain · 残量リング	TokenRemain · 잔여 링
widget.name.corner	TokenRemain · 角標	TokenRemain · Esquina	TokenRemain · Ecke	TokenRemain · コーナー	TokenRemain · 모서리
widget.name.inline	TokenRemain · 單行	TokenRemain · En línea	TokenRemain · Inline	TokenRemain · インライン	TokenRemain · 인라인
widget.desc.min	最低剩餘額度	Cuota mínima restante	Niedrigstes Restkontingent	最小残量	최소 잔여 한도
widget.desc.reset	下次額度重置	Próximo reinicio de cuota	Nächste Kontingent-Zurücksetzung	次回の上限リセット	다음 한도 재설정
widget.desc.quota	Claude 與 Codex 額度	Cuota de Claude y Codex	Claude- und Codex-Kontingent	Claude と Codex の上限	Claude 및 Codex 한도
widget.desc.rings	Claude + Codex 剩餘圓環	Anillos restantes de Claude + Codex	Restringe für Claude + Codex	Claude + Codex の残量リング	Claude + Codex 잔여 링
widget.desc.status	額度狀態	Estado de cuota	Kontingentstatus	上限の状態	한도 상태
widget.desc.corner	AI 用量 · 最低剩餘	Uso de IA · mínimo restante	KI-Nutzung · niedrigster Restwert	AI 使用量 · 最小残量	AI 사용량 · 최소 잔여량
"""
}
