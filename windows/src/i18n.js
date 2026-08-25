import catalogs from "./locales.generated.js";

export const SUPPORTED_LANGUAGES = ["en", "zh-Hans", "zh-Hant", "ja", "ko", "es", "de"];
export const SYSTEM_LANGUAGE = "system";

const LANGUAGE_NAMES = {
  en: "English",
  "zh-Hans": "简体中文",
  "zh-Hant": "繁體中文",
  ja: "日本語",
  ko: "한국어",
  es: "Español",
  de: "Deutsch",
};

const WINDOWS_MESSAGES = {
  "Cursor Models": { "zh-Hans": "Cursor 模型", "zh-Hant": "Cursor 模型", ja: "Cursor モデル", ko: "Cursor 모델", es: "Modelos de Cursor", de: "Cursor-Modelle" },
  "Other Models": { "zh-Hans": "其他模型", "zh-Hant": "其他模型", ja: "その他のモデル", ko: "기타 모델", es: "Otros modelos", de: "Andere Modelle" },
  Chat: { "zh-Hans": "聊天", "zh-Hant": "聊天", ja: "チャット", ko: "채팅", es: "Chat", de: "Chat" },
  Completions: { "zh-Hans": "补全", "zh-Hant": "補全", ja: "コード補完", ko: "코드 완성", es: "Autocompletado", de: "Vervollständigungen" },
  Personal: { "zh-Hans": "个人", "zh-Hant": "個人", ja: "個人", ko: "개인", es: "Personal", de: "Persönlich" },
  Shared: { "zh-Hans": "共享", "zh-Hant": "共用", ja: "共有", ko: "공유", es: "Compartido", de: "Geteilt" },
  Daily: { "zh-Hans": "每日", "zh-Hant": "每日", ja: "日次", ko: "일일", es: "Diario", de: "Täglich" },
  Hourly: { "zh-Hans": "每小时", "zh-Hant": "每小時", ja: "時間別", ko: "시간별", es: "Por hora", de: "Stündlich" },
  Credits: { "zh-Hans": "积分", "zh-Hant": "點數", ja: "クレジット", ko: "크레딧", es: "Créditos", de: "Guthaben" },
  "%1$@ is signed out": {
    "zh-Hans": "%1$@ 已登出", "zh-Hant": "%1$@ 已登出", ja: "%1$@ からログアウトされています", ko: "%1$@에서 로그아웃되었습니다", es: "Se cerró la sesión de %1$@", de: "%1$@ ist abgemeldet",
  },
  "TokenRemain can no longer read your usage — the cards are showing the last good snapshot. Sign in to %1$@ again to restore it.": {
    "zh-Hans": "TokenRemain 已读不到用量，卡片显示的是最后一次成功的快照。重新登录 %1$@ 后自动恢复。",
    "zh-Hant": "TokenRemain 已讀不到用量，卡片顯示的是最後一次成功的快照。重新登入 %1$@ 後自動恢復。",
    ja: "TokenRemain は使用量を読み取れなくなりました。カードは最後に取得できた値を表示しています。%1$@ に再度ログインすると復旧します。",
    ko: "TokenRemain이 사용량을 읽을 수 없습니다. 카드는 마지막으로 성공한 스냅샷을 표시하고 있습니다. %1$@에 다시 로그인하면 복구됩니다.",
    es: "TokenRemain ya no puede leer tu uso: las tarjetas muestran la última instantánea correcta. Vuelve a iniciar sesión en %1$@ para restaurarlo.",
    de: "TokenRemain kann deine Nutzung nicht mehr lesen – die Karten zeigen den letzten gültigen Stand. Melde dich wieder bei %1$@ an, um sie wiederherzustellen.",
  },
  "System default": { "zh-Hans": "跟随系统", "zh-Hant": "跟隨系統", ja: "システム設定", ko: "시스템 기본값", es: "Predeterminado del sistema", de: "Systemstandard" },
  Language: { "zh-Hans": "语言", "zh-Hant": "語言", ja: "言語", ko: "언어", es: "Idioma", de: "Sprache" },
  "Follow the Windows display language automatically, or choose a language for TokenRemain.": {
    "zh-Hans": "自动跟随 Windows 显示语言，或为 TokenRemain 单独选择语言。",
    "zh-Hant": "自動跟隨 Windows 顯示語言，或為 TokenRemain 單獨選擇語言。",
    ja: "Windows の表示言語に自動で合わせるか、TokenRemain の言語を選択します。",
    ko: "Windows 표시 언어를 자동으로 따르거나 TokenRemain 언어를 선택하세요.",
    es: "Sigue automáticamente el idioma de Windows o elige uno para TokenRemain.",
    de: "Automatisch der Windows-Anzeigesprache folgen oder eine Sprache für TokenRemain wählen.",
  },
  "Show Antigravity third-party pools": {
    "zh-Hans": "显示 Antigravity 第三方额度池", "zh-Hant": "顯示 Antigravity 第三方額度池", ja: "Antigravity のサードパーティ枠を表示", ko: "Antigravity 타사 할당량 풀 표시", es: "Mostrar los cupos de terceros de Antigravity", de: "Antigravity-Drittanbieter-Kontingente anzeigen",
  },
  "Show the optional Claude/third-party 5-hour and weekly pools; hidden by default.": {
    "zh-Hans": "显示可选的 Claude/第三方 5 小时与周额度；默认隐藏。",
    "zh-Hant": "顯示可選的 Claude/第三方 5 小時與每週額度；預設隱藏。",
    ja: "オプションの Claude／サードパーティの 5 時間枠と週間枠を表示します。既定では非表示です。",
    ko: "선택 사항인 Claude/타사 5시간 및 주간 할당량 풀을 표시합니다. 기본적으로 숨겨집니다.",
    es: "Muestra los cupos opcionales de Claude/terceros de 5 horas y semanales; están ocultos de forma predeterminada.",
    de: "Zeigt die optionalen 5-Stunden- und Wochenkontingente für Claude/Drittanbieter; standardmäßig ausgeblendet.",
  },
  "Usage over time · local on this PC, optionally synced from Mac": {
    "zh-Hans": "使用趋势 · 本机数据，可选与 Mac 同步", "zh-Hant": "使用趨勢 · 本機資料，可選與 Mac 同步", ja: "使用状況の推移 · この PC のローカルデータ、任意で Mac と同期", ko: "시간별 사용량 · 이 PC의 로컬 데이터, 선택적으로 Mac과 동기화", es: "Uso a lo largo del tiempo · local en este PC, sincronización opcional con Mac", de: "Nutzung im Zeitverlauf · lokal auf diesem PC, optional mit dem Mac synchronisiert",
  },
  "This PC and its encrypted Mac link": {
    "zh-Hans": "本机及其加密 Mac 连接", "zh-Hant": "本機及其加密 Mac 連線", ja: "この PC と暗号化された Mac 接続", ko: "이 PC와 암호화된 Mac 연결", es: "Este PC y su enlace cifrado con Mac", de: "Dieser PC und seine verschlüsselte Mac-Verbindung",
  },
  "Data-source status and privacy": {
    "zh-Hans": "数据源状态与隐私", "zh-Hant": "資料來源狀態與隱私", ja: "データソースの状態とプライバシー", ko: "데이터 소스 상태 및 개인정보 보호", es: "Estado y privacidad de las fuentes de datos", de: "Datenquellenstatus und Datenschutz",
  },
  "Quick View, startup, and app controls": {
    "zh-Hans": "快速查看、启动与应用控制", "zh-Hant": "快速檢視、啟動與應用程式控制", ja: "クイックビュー、起動、アプリ操作", ko: "빠른 보기, 시작 및 앱 제어", es: "Vista rápida, inicio y controles de la aplicación", de: "Schnellansicht, Start und App-Steuerung",
  },
  "We scanned this Windows PC. Detected AI tools are already checked; choose what TokenRemain should monitor locally.": {
    "zh-Hans": "我们已扫描这台 Windows 电脑。检测到的 AI 工具已自动勾选，请选择 TokenRemain 要在本机监控的应用。",
    "zh-Hant": "我們已掃描這台 Windows 電腦。偵測到的 AI 工具已自動勾選，請選擇 TokenRemain 要在本機監控的應用程式。",
    ja: "この Windows PC をスキャンしました。検出した AI ツールは選択済みです。TokenRemain がローカルで監視するものを選んでください。",
    ko: "이 Windows PC를 스캔했습니다. 감지된 AI 도구는 이미 선택되어 있습니다. TokenRemain이 로컬에서 모니터링할 항목을 선택하세요.",
    es: "Hemos analizado este PC con Windows. Las herramientas de IA detectadas ya están marcadas; elige qué debe supervisar TokenRemain localmente.",
    de: "Dieser Windows-PC wurde durchsucht. Erkannte KI-Tools sind bereits ausgewählt; wähle aus, was TokenRemain lokal überwachen soll.",
  },
  "Detection is local and read-only. Credentials stay on this PC and are never sent to your Mac.": {
    "zh-Hans": "检测仅在本机以只读方式完成。凭据保留在这台电脑上，绝不会发送到 Mac。",
    "zh-Hant": "偵測僅在本機以唯讀方式完成。憑證保留在這台電腦上，絕不會傳送到 Mac。",
    ja: "検出はローカルかつ読み取り専用です。認証情報はこの PC に残り、Mac には送信されません。",
    ko: "감지는 로컬에서 읽기 전용으로 수행됩니다. 자격 증명은 이 PC에만 보관되며 Mac으로 전송되지 않습니다.",
    es: "La detección es local y de solo lectura. Las credenciales permanecen en este PC y nunca se envían al Mac.",
    de: "Die Erkennung erfolgt lokal und schreibgeschützt. Anmeldedaten bleiben auf diesem PC und werden nie an den Mac gesendet.",
  },
  "Open Quick View": { "zh-Hans": "打开快速查看", "zh-Hant": "開啟快速檢視", ja: "クイックビューを開く", ko: "빠른 보기 열기", es: "Abrir vista rápida", de: "Schnellansicht öffnen" },
  "Floating shortcut": { "zh-Hans": "浮动快捷组件", "zh-Hant": "浮動快捷元件", ja: "フローティングショートカット", ko: "플로팅 바로가기", es: "Acceso flotante", de: "Schwebende Verknüpfung" },
  "This Windows PC": { "zh-Hans": "这台 Windows 电脑", "zh-Hant": "這台 Windows 電腦", ja: "この Windows PC", ko: "이 Windows PC", es: "Este PC con Windows", de: "Dieser Windows-PC" },
  "Windows-local providers": { "zh-Hans": "Windows 本地应用", "zh-Hant": "Windows 本機應用程式", ja: "Windows ローカルプロバイダー", ko: "Windows 로컬 공급자", es: "Proveedores locales de Windows", de: "Lokale Windows-Anbieter" },
  "System language": { "zh-Hans": "系统语言", "zh-Hant": "系統語言", ja: "システム言語", ko: "시스템 언어", es: "Idioma del sistema", de: "Systemsprache" },
  "Open Dashboard": { "zh-Hans": "打开仪表盘", "zh-Hant": "開啟儀表板", ja: "ダッシュボードを開く", ko: "대시보드 열기", es: "Abrir panel", de: "Dashboard öffnen" },
  "Show Floating Shortcut": { "zh-Hans": "显示浮动快捷组件", "zh-Hant": "顯示浮動快捷元件", ja: "フローティングショートカットを表示", ko: "플로팅 바로가기 표시", es: "Mostrar acceso flotante", de: "Schwebende Verknüpfung anzeigen" },
  "Hide Floating Shortcut": { "zh-Hans": "隐藏浮动快捷组件", "zh-Hant": "隱藏浮動快捷元件", ja: "フローティングショートカットを隠す", ko: "플로팅 바로가기 숨기기", es: "Ocultar acceso flotante", de: "Schwebende Verknüpfung ausblenden" },
  "By provider": { "zh-Hans": "按服务商统计", "zh-Hant": "按服務商統計", ja: "プロバイダー別", ko: "제공업체별", es: "Por proveedor", de: "Nach Anbieter" },
  Trending: { "zh-Hans": "热门动态", "zh-Hant": "熱門動態", ja: "トレンド", ko: "트렌드", es: "Tendencias", de: "Trends" },
  "Public TokenRemain feed": { "zh-Hans": "TokenRemain 公共信息源", "zh-Hant": "TokenRemain 公開資訊來源", ja: "TokenRemain 公開フィード", ko: "TokenRemain 공개 피드", es: "Feed público de TokenRemain", de: "Öffentlicher TokenRemain-Feed" },
  "This PC + paired Mac": { "zh-Hans": "本机 + 已配对 Mac", "zh-Hant": "本機 + 已配對 Mac", ja: "この PC + ペアリング済み Mac", ko: "이 PC + 페어링된 Mac", es: "Este PC + Mac emparejado", de: "Dieser PC + gekoppelter Mac" },
  "this PC": { "zh-Hans": "本机", "zh-Hant": "本機", ja: "この PC", ko: "이 PC", es: "este PC", de: "diesem PC" },
  "Captured %1$@ from %2$@.": { "zh-Hans": "%1$@ 采集自%2$@。", "zh-Hant": "%1$@ 擷取自%2$@。", ja: "%2$@ から %1$@ に取得。", ko: "%2$@에서 %1$@에 수집됨.", es: "Capturado a las %1$@ desde %2$@.", de: "Um %1$@ von %2$@ erfasst." },
  "%1$@ %2$@ runs out in %3$@": { "zh-Hans": "%1$@ %2$@将在 %3$@ 后用尽", "zh-Hant": "%1$@ %2$@ 將在 %3$@ 後用盡", ja: "%1$@ の %2$@ は %3$@ 後に上限到達", ko: "%1$@ %2$@은(는) %3$@ 후 소진", es: "%1$@ %2$@ se agota en %3$@", de: "%1$@ %2$@ ist in %3$@ aufgebraucht" },
  tokens: { "zh-Hans": "tokens", "zh-Hant": "tokens", ja: "トークン", ko: "토큰", es: "tokens", de: "Token" },
  "Startup, quick view, and floating shortcut": { "zh-Hans": "启动、快速查看与浮动快捷组件", "zh-Hant": "啟動、快速檢視與浮動快捷元件", ja: "起動、クイックビュー、フローティングショートカット", ko: "시작, 빠른 보기 및 플로팅 바로가기", es: "Inicio, vista rápida y acceso flotante", de: "Start, Schnellansicht und schwebende Verknüpfung" },
  "Show the Dashboard in the taskbar": { "zh-Hans": "在任务栏显示仪表盘窗口图标", "zh-Hant": "在工作列顯示儀表板視窗圖示", ja: "タスクバーにダッシュボードを表示", ko: "작업 표시줄에 대시보드 표시", es: "Mostrar el Dashboard en la barra de tareas", de: "Dashboard in der Taskleiste anzeigen" },
  "Keep the Dashboard window available in the Windows taskbar.": { "zh-Hans": "让仪表盘窗口持续显示在 Windows 任务栏中。", "zh-Hant": "讓儀表板視窗持續顯示在 Windows 工作列中。", ja: "Dashboard ウインドウを Windows のタスクバーから開けるようにします。", ko: "Windows 작업 표시줄에서 대시보드 창을 계속 사용할 수 있게 합니다.", es: "Mantén la ventana del Dashboard disponible en la barra de tareas de Windows.", de: "Hält das Dashboard-Fenster in der Windows-Taskleiste verfügbar." },
  // Windows-only source strings for the two model-quota toggles. The shared
  // catalog's originals talk about the macOS menu bar; rather than edit the
  // generated catalog, main.jsx passes these tray-worded sources and picks up
  // the translations here (English needs no entry — tr() falls through to the
  // source when neither table nor catalog matches).
  "Show Fable in the tray Claude widget": { "zh-Hans": "在托盘 Claude 组件显示 Fable", "zh-Hant": "在系統匣 Claude 元件顯示 Fable", ja: "トレイの Claude ウィジェットに Fable を表示", ko: "트레이 Claude 위젯에 Fable 표시", es: "Mostrar Fable en el widget de Claude de la bandeja", de: "Fable im Claude-Widget im Infobereich anzeigen" },
  "Displays Fable's weekly limit in the Claude quota widget in the Windows tray.": { "zh-Hans": "在 Windows 托盘的 Claude 额度组件中显示 Fable 的每周额度。", "zh-Hant": "在 Windows 系統匣的 Claude 額度元件中顯示 Fable 的每週額度。", ja: "Windows トレイの Claude 上限ウィジェットに Fable の週間上限を表示します。", ko: "Windows 트레이의 Claude 한도 위젯에 Fable의 주간 한도를 표시합니다.", es: "Muestra el límite semanal de Fable en el widget de cuota de Claude de la bandeja de Windows.", de: "Zeigt das Wochenlimit von Fable im Claude-Kontingent-Widget im Windows-Infobereich an." },
  "Show GPT-5.3-Codex-Spark in the tray Codex widget": { "zh-Hans": "在托盘 Codex 组件显示 GPT-5.3-Codex-Spark", "zh-Hant": "在系統匣 Codex 元件顯示 GPT-5.3-Codex-Spark", ja: "トレイの Codex ウィジェットに GPT-5.3-Codex-Spark を表示", ko: "트레이 Codex 위젯에 GPT-5.3-Codex-Spark 표시", es: "Mostrar GPT-5.3-Codex-Spark en el widget de Codex de la bandeja", de: "GPT-5.3-Codex-Spark im Codex-Widget im Infobereich anzeigen" },
  "Displays the model-specific weekly limit in the Codex quota widget in the Windows tray.": { "zh-Hans": "在 Windows 托盘的 Codex 额度组件中显示该模型的每周额度。", "zh-Hant": "在 Windows 系統匣的 Codex 額度元件中顯示該模型的每週額度。", ja: "Windows トレイの Codex 上限ウィジェットにモデル固有の週間上限を表示します。", ko: "Windows 트레이의 Codex 한도 위젯에 모델별 주간 한도를 표시합니다.", es: "Muestra el límite semanal específico del modelo en el widget de cuota de Codex de la bandeja de Windows.", de: "Zeigt das modellspezifische Wochenlimit im Codex-Kontingent-Widget im Windows-Infobereich an." },
  "Tray icon": { "zh-Hans": "托盘图标", "zh-Hant": "系統匣圖示", ja: "トレイアイコン", ko: "트레이 아이콘", es: "Icono de la bandeja", de: "Infobereich-Symbol" },
  "Show live quota in the Windows tray as a number, two rings, or one ring.": { "zh-Hans": "在 Windows 托盘中以数字、双环或单环显示实时额度。", "zh-Hant": "在 Windows 系統匣中以數字、雙環或單環顯示即時額度。", ja: "Windows のトレイに残量を数字、2 本のリング、または 1 本のリングで表示します。", ko: "Windows 트레이에 실시간 할당량을 숫자, 이중 링 또는 단일 링으로 표시합니다.", es: "Muestra la cuota en directo en la bandeja de Windows como número, dos anillos o un anillo.", de: "Zeigt das Live-Kontingent im Windows-Infobereich als Zahl, zwei Ringe oder einen Ring." },
  "Tray providers": { "zh-Hans": "托盘服务商", "zh-Hant": "系統匣服務商", ja: "トレイのプロバイダー", ko: "트레이 제공업체", es: "Proveedores de la bandeja", de: "Anbieter im Infobereich" },
  "Choose up to 4 providers; compact mode draws the first two selected providers.": { "zh-Hans": "最多选择 4 个服务商；紧凑模式会绘制前两个已选服务商。", "zh-Hant": "最多選擇 4 個服務商；精簡模式會繪製前兩個已選服務商。", ja: "最大 4 つ選択できます。コンパクトモードでは最初の 2 つを描画します。", ko: "최대 4개 제공업체를 선택하세요. 컴팩트 모드는 처음 선택한 두 개를 그립니다.", es: "Elige hasta 4 proveedores; el modo compacto dibuja los dos primeros seleccionados.", de: "Bis zu 4 Anbieter auswählen; im kompakten Modus werden die ersten beiden dargestellt." },
  "Start TokenRemain automatically when you sign in to Windows; it keeps monitoring from the tray.": { "zh-Hans": "登录 Windows 时自动启动 TokenRemain，并在系统托盘中持续监控。", "zh-Hant": "登入 Windows 時自動啟動 TokenRemain，並在系統匣中持續監控。", ja: "Windows へのサインイン時に TokenRemain を起動し、トレイから監視を続けます。", ko: "Windows 로그인 시 TokenRemain을 자동 시작하고 트레이에서 계속 모니터링합니다.", es: "Inicia TokenRemain al entrar en Windows y mantén la supervisión desde la bandeja.", de: "TokenRemain bei der Windows-Anmeldung starten und über den Infobereich weiter überwachen." },
  "Keep a small quota shortcut above other windows. Drag its grip to move it; click the quota to open Quick View.": { "zh-Hans": "在其他窗口上方显示小型额度组件。拖动顶部把手可移动，点击额度可打开快速查看。", "zh-Hant": "在其他視窗上方顯示小型額度元件。拖曳頂部把手可移動，點擊額度可開啟快速檢視。", ja: "ほかのウィンドウより前面に小さな上限ウィジェットを表示します。グリップで移動し、上限をクリックするとクイックビューが開きます。", ko: "다른 창 위에 작은 한도 위젯을 표시합니다. 손잡이를 끌어 이동하고 한도를 클릭해 빠른 보기를 여세요.", es: "Muestra un pequeño acceso de cuota sobre otras ventanas. Arrástralo para moverlo y haz clic para abrir la vista rápida.", de: "Kleine Kontingentanzeige über anderen Fenstern einblenden. Am Griff verschieben; ein Klick öffnet die Schnellansicht." },
  "Quick View popup": { "zh-Hans": "快速查看浮窗", "zh-Hant": "快速檢視浮窗", ja: "クイックビューのポップアップ", ko: "빠른 보기 팝업", es: "Ventana de vista rápida", de: "Schnellansicht-Popup" },
  "Open the same compact popup as a tray-icon click. This is separate from the full Dashboard.": { "zh-Hans": "打开与点击托盘图标相同的紧凑浮窗；它独立于完整仪表盘。", "zh-Hant": "開啟與點擊系統匣圖示相同的精簡浮窗；它獨立於完整儀表板。", ja: "トレイアイコンと同じコンパクトなポップアップを開きます。完全版ダッシュボードとは別です。", ko: "트레이 아이콘 클릭과 같은 간단한 팝업을 엽니다. 전체 대시보드와는 별도입니다.", es: "Abre la misma ventana compacta que el icono de la bandeja, separada del panel completo.", de: "Öffnet dasselbe kompakte Popup wie ein Klick auf das Taskleistensymbol; getrennt vom vollständigen Dashboard." },
  "Open now": { "zh-Hans": "立即打开", "zh-Hant": "立即開啟", ja: "今すぐ開く", ko: "지금 열기", es: "Abrir ahora", de: "Jetzt öffnen" },
  "Close button": { "zh-Hans": "关闭按钮", "zh-Hant": "關閉按鈕", ja: "閉じるボタン", ko: "닫기 버튼", es: "Botón de cierre", de: "Schließen-Schaltfläche" },
  "Closing the window keeps TokenRemain running in the tray; quit from the tray menu or Settings › About.": { "zh-Hans": "关闭窗口后 TokenRemain 仍会在系统托盘中运行；可从托盘菜单或“设置 › 关于”退出。", "zh-Hant": "關閉視窗後 TokenRemain 仍會在系統匣中執行；可從系統匣選單或「設定 › 關於」結束。", ja: "ウィンドウを閉じても TokenRemain はトレイで動作します。終了するにはトレイメニューまたは「設定 › 情報」を使います。", ko: "창을 닫아도 TokenRemain은 트레이에서 실행됩니다. 트레이 메뉴 또는 설정 › 정보에서 종료하세요.", es: "Al cerrar la ventana, TokenRemain sigue en la bandeja; sal desde su menú o en Ajustes › Acerca de.", de: "Beim Schließen läuft TokenRemain im Infobereich weiter; Beenden über das Infobereich-Menü oder Einstellungen › Info." },
  "Local CLI quotas, the Mac link, and the curated feed refresh together on a fixed cadence.": { "zh-Hans": "本地 CLI 额度、Mac 连接和精选信息源会按固定周期一并刷新。", "zh-Hant": "本機 CLI 額度、Mac 連線和精選資訊來源會依固定週期一併重新整理。", ja: "ローカル CLI の上限、Mac 接続、厳選フィードを一定間隔でまとめて更新します。", ko: "로컬 CLI 한도, Mac 연결 및 선별 피드를 일정 주기로 함께 새로 고칩니다.", es: "Las cuotas de CLI local, el enlace con Mac y el feed se actualizan juntos a intervalos fijos.", de: "Lokale CLI-Kontingente, Mac-Verbindung und kuratierter Feed werden gemeinsam in festem Rhythmus aktualisiert." },
  "Refresh interval": { "zh-Hans": "刷新间隔", "zh-Hant": "重新整理間隔", ja: "更新間隔", ko: "새로 고침 간격", es: "Intervalo de actualización", de: "Aktualisierungsintervall" },
  "Every minute": { "zh-Hans": "每分钟", "zh-Hant": "每分鐘", ja: "毎分", ko: "매분", es: "Cada minuto", de: "Jede Minute" },
  "Every 15 minutes": { "zh-Hans": "每 15 分钟", "zh-Hant": "每 15 分鐘", ja: "15 分ごと", ko: "15분마다", es: "Cada 15 minutos", de: "Alle 15 Minuten" },
  "Every 30 minutes": { "zh-Hans": "每 30 分钟", "zh-Hant": "每 30 分鐘", ja: "30 分ごと", ko: "30분마다", es: "Cada 30 minutos", de: "Alle 30 Minuten" },
  Manually: { "zh-Hans": "手动", "zh-Hant": "手動", ja: "手動", ko: "수동", es: "Manualmente", de: "Manuell" },
  "Encrypted direct sync between your devices": { "zh-Hans": "设备间加密直连同步", "zh-Hant": "裝置間加密直連同步", ja: "デバイス間の暗号化ダイレクト同期", ko: "기기 간 암호화 직접 동기화", es: "Sincronización directa cifrada entre dispositivos", de: "Verschlüsselte Direktsynchronisierung zwischen Geräten" },
  "Encrypted direct sync": { "zh-Hans": "加密直连同步", "zh-Hant": "加密直連同步", ja: "暗号化ダイレクト同期", ko: "암호화 직접 동기화", es: "Sincronización directa cifrada", de: "Verschlüsselte Direktsynchronisierung" },
  "Manage devices": { "zh-Hans": "管理设备", "zh-Hant": "管理裝置", ja: "デバイスを管理", ko: "기기 관리", es: "Gestionar dispositivos", de: "Geräte verwalten" },
  "Local-first · encrypted LAN sync with your Mac": { "zh-Hans": "本地优先 · 与 Mac 进行局域网加密同步", "zh-Hant": "本機優先 · 與 Mac 進行區域網路加密同步", ja: "ローカル優先 · Mac との暗号化 LAN 同期", ko: "로컬 우선 · Mac과 암호화된 LAN 동기화", es: "Local primero · sincronización LAN cifrada con tu Mac", de: "Local-first · verschlüsselte LAN-Synchronisierung mit dem Mac" },
  "Credential access": { "zh-Hans": "凭据访问", "zh-Hant": "憑證存取", ja: "認証情報へのアクセス", ko: "자격 증명 접근", es: "Acceso a credenciales", de: "Zugriff auf Anmeldedaten" },
  "Read-only local CLI files": { "zh-Hans": "只读访问本地 CLI 文件", "zh-Hant": "唯讀存取本機 CLI 檔案", ja: "ローカル CLI ファイルを読み取り専用で使用", ko: "로컬 CLI 파일 읽기 전용", es: "Archivos CLI locales de solo lectura", de: "Lokale CLI-Dateien nur lesen" },
  "Last sync %1$@": { "zh-Hans": "上次同步：%1$@", "zh-Hant": "上次同步：%1$@", ja: "最終同期：%1$@", ko: "마지막 동기화: %1$@", es: "Última sincronización: %1$@", de: "Letzte Synchronisierung: %1$@" },
  "%1$@ ago": { "zh-Hans": "%1$@前", "zh-Hant": "%1$@前", ja: "%1$@前", ko: "%1$@ 전", es: "hace %1$@", de: "vor %1$@" },
  "just now": { "zh-Hans": "刚刚", "zh-Hant": "剛剛", ja: "たった今", ko: "방금", es: "ahora mismo", de: "gerade eben" },
  "This PC": { "zh-Hans": "本机", "zh-Hant": "本機", ja: "この PC", ko: "이 PC", es: "Este PC", de: "Dieser PC" },
  "Drag the top grip to move · right-click for more options": { "zh-Hans": "拖动顶部把手可移动 · 右键查看更多选项", "zh-Hant": "拖曳頂部把手可移動 · 右鍵查看更多選項", ja: "上部のグリップで移動 · 右クリックでその他のオプション", ko: "상단 손잡이를 끌어 이동 · 우클릭하여 추가 옵션", es: "Arrastra el tirador superior para mover · clic derecho para más opciones", de: "Am oberen Griff verschieben · Rechtsklick für weitere Optionen" },
  // %2$@ is the list of providers the widget is actually drawing, built from
  // the live snapshot — never a fixed Claude/Codex pair.
  "Lowest remaining %1$@. %2$@.": { "zh-Hans": "最低剩余 %1$@。%2$@。", "zh-Hant": "最低剩餘 %1$@。%2$@。", ja: "最小残量 %1$@。%2$@。", ko: "최저 잔여량 %1$@. %2$@.", es: "Mínimo restante: %1$@. %2$@.", de: "Niedrigster Restwert %1$@. %2$@." },
  "Quota is not available yet": { "zh-Hans": "额度暂不可用", "zh-Hant": "額度暫不可用", ja: "上限はまだ利用できません", ko: "아직 한도를 확인할 수 없습니다", es: "La cuota aún no está disponible", de: "Kontingent noch nicht verfügbar" },
  Open: { "zh-Hans": "打开", "zh-Hant": "開啟", ja: "開く", ko: "열기", es: "Abrir", de: "Öffnen" },
  Close: { "zh-Hans": "关闭", "zh-Hant": "關閉", ja: "閉じる", ko: "닫기", es: "Cerrar", de: "Schließen" },
  "Quick View": { "zh-Hans": "快速查看", "zh-Hant": "快速檢視", ja: "クイックビュー", ko: "빠른 보기", es: "Vista rápida", de: "Schnellansicht" },
  "%1$d apps shown · drag cards to reorder": { "zh-Hans": "显示 %1$d 个应用 · 拖动卡片可排序", "zh-Hant": "顯示 %1$d 個應用程式 · 拖曳卡片可排序", ja: "%1$d 個のアプリを表示 · カードをドラッグして並べ替え", ko: "%1$d개 앱 표시 · 카드를 끌어 순서 변경", es: "%1$d aplicaciones · arrastra las tarjetas para ordenar", de: "%1$d Apps angezeigt · Karten zum Sortieren ziehen" },
  "Projected to run out in %1$@": { "zh-Hans": "预计 %1$@ 后用尽", "zh-Hant": "預計 %1$@ 後用盡", ja: "%1$@ 後に上限到達見込み", ko: "%1$@ 후 소진 예상", es: "Se agotará en %1$@", de: "Voraussichtlich in %1$@ aufgebraucht" },
  "Use Add app and the minus control to choose which Windows-local adapters TokenRemain monitors. Automatic adapters reuse the app's existing sign-in; credential adapters are configured locally in Data Sources.": { "zh-Hans": "使用“添加应用”和减号选择 TokenRemain 监控的 Windows 本地适配器。自动适配器复用应用现有登录；凭据适配器在“数据来源”中配置。", "zh-Hant": "使用「新增應用程式」和減號選擇 TokenRemain 監控的 Windows 本機介接器。自動介接器沿用應用程式現有登入；憑證介接器在「資料來源」中設定。", ja: "「アプリを追加」とマイナスボタンで監視する Windows ローカルアダプターを選びます。自動アダプターは既存のサインインを再利用し、認証情報はデータソースで設定します。", ko: "앱 추가와 빼기 버튼으로 모니터링할 Windows 로컬 어댑터를 선택합니다. 자동 어댑터는 기존 로그인을 재사용하며 자격 증명은 데이터 소스에서 설정합니다.", es: "Usa Añadir aplicación y el control menos para elegir adaptadores locales de Windows. Los automáticos reutilizan el inicio de sesión; las credenciales se configuran en Fuentes de datos.", de: "Mit „App hinzufügen“ und Minus die lokalen Windows-Adapter wählen. Automatische Adapter nutzen die bestehende Anmeldung; Zugangsdaten werden unter Datenquellen eingerichtet." },
  "Mac Direct Sync is fallback-only: it fills a provider only when this PC has no local snapshot, and never replaces a Windows-local reading.": { "zh-Hans": "Mac Direct Sync 仅作备用：只有本机没有本地快照时才补充服务商数据，绝不会替换 Windows 本地读数。", "zh-Hant": "Mac Direct Sync 僅作備援：只有本機沒有本機快照時才補充服務商資料，絕不會取代 Windows 本機讀數。", ja: "Mac Direct Sync はフォールバック専用です。この PC にローカルスナップショットがない場合のみ補完し、Windows のローカル値を置き換えません。", ko: "Mac Direct Sync는 보조 수단입니다. 이 PC에 로컬 스냅샷이 없을 때만 채우며 Windows 로컬 값을 대체하지 않습니다.", es: "Mac Direct Sync solo actúa como respaldo: completa un proveedor si este PC no tiene captura local y nunca sustituye una lectura local de Windows.", de: "Mac Direct Sync dient nur als Fallback: Es ergänzt Anbieter ohne lokalen Snapshot und ersetzt nie eine lokale Windows-Messung." },
  "Drag a full card to reorder it — Alt plus arrow keys also works — and both order and visibility are remembered on this PC.": { "zh-Hans": "拖动整张卡片可排序，也可使用 Alt 加方向键；顺序和显示状态都会保存在本机。", "zh-Hant": "拖曳整張卡片可排序，也可使用 Alt 加方向鍵；順序和顯示狀態都會儲存在本機。", ja: "カード全体をドラッグ、または Alt + 矢印キーで並べ替えられます。順序と表示状態はこの PC に保存されます。", ko: "전체 카드를 끌거나 Alt+화살표 키로 순서를 바꿀 수 있으며 순서와 표시 상태는 이 PC에 저장됩니다.", es: "Arrastra la tarjeta completa o usa Alt y las flechas; el orden y la visibilidad se guardan en este PC.", de: "Die ganze Karte ziehen oder Alt plus Pfeiltasten verwenden; Reihenfolge und Sichtbarkeit werden auf diesem PC gespeichert." },
  "Detected apps stacked · local and synced aggregate": { "zh-Hans": "已检测应用堆叠 · 本地与同步汇总", "zh-Hant": "已偵測應用程式堆疊 · 本機與同步彙總", ja: "検出アプリを積み上げ表示 · ローカルと同期データの集計", ko: "감지된 앱 누적 · 로컬 및 동기화 합계", es: "Aplicaciones detectadas apiladas · agregado local y sincronizado", de: "Erkannte Apps gestapelt · lokale und synchronisierte Summe" },
  "Where the trend starts": { "zh-Hans": "趋势起点", "zh-Hant": "趨勢起點", ja: "トレンドの起点", ko: "추세 시작점", es: "Inicio de la tendencia", de: "Ausgangspunkt des Trends" },
  "History coverage": { "zh-Hans": "历史覆盖", "zh-Hant": "歷史涵蓋", ja: "履歴の範囲", ko: "기록 범위", es: "Cobertura del historial", de: "Verlaufabdeckung" },
  "Local aggregate, with optional Mac contribution": { "zh-Hans": "本地汇总，可选加入 Mac 数据", "zh-Hant": "本機彙總，可選加入 Mac 資料", ja: "ローカル集計（任意で Mac データを追加）", ko: "로컬 합계, 선택적으로 Mac 데이터 포함", es: "Agregado local con contribución opcional del Mac", de: "Lokale Summe mit optionalem Mac-Anteil" },
  "Recorded days": { "zh-Hans": "已记录天数", "zh-Hant": "已記錄天數", ja: "記録日数", ko: "기록 일수", es: "Días registrados", de: "Erfasste Tage" },
  "Oldest day": { "zh-Hans": "最早日期", "zh-Hant": "最早日期", ja: "最古の日", ko: "가장 오래된 날짜", es: "Día más antiguo", de: "Ältester Tag" },
  "Latest day": { "zh-Hans": "最新日期", "zh-Hant": "最新日期", ja: "最新の日", ko: "최근 날짜", es: "Día más reciente", de: "Neuester Tag" },
  "Quota history": { "zh-Hans": "额度历史", "zh-Hant": "額度歷史", ja: "上限履歴", ko: "한도 기록", es: "Historial de cuota", de: "Kontingentverlauf" },
  "%1$d local snapshots": { "zh-Hans": "%1$d 个本地快照", "zh-Hant": "%1$d 個本機快照", ja: "%1$d 件のローカルスナップショット", ko: "%1$d개 로컬 스냅샷", es: "%1$d capturas locales", de: "%1$d lokale Snapshots" },
  Accumulating: { "zh-Hans": "正在积累", "zh-Hant": "正在累積", ja: "蓄積中", ko: "누적 중", es: "Acumulando", de: "Wird gesammelt" },
  "No supported coding-agent usage recorded today yet.": { "zh-Hans": "今天尚未记录到受支持编码代理的用量。", "zh-Hant": "今天尚未記錄到受支援編碼代理的用量。", ja: "今日はまだ対応コーディングエージェントの使用量がありません。", ko: "오늘 기록된 지원 코딩 에이전트 사용량이 없습니다.", es: "Aún no hay uso registrado hoy de agentes compatibles.", de: "Heute wurde noch keine Nutzung unterstützter Coding-Agenten erfasst." },
  "Source ID": { "zh-Hans": "来源 ID", "zh-Hant": "來源 ID", ja: "ソース ID", ko: "소스 ID", es: "ID de origen", de: "Quell-ID" },
  "Mac direct sync": { "zh-Hans": "Mac 直连同步", "zh-Hant": "Mac 直連同步", ja: "Mac ダイレクト同期", ko: "Mac 직접 동기화", es: "Sincronización directa con Mac", de: "Direktsynchronisierung mit Mac" },
  "Quota snapshots and optional daily aggregates; provider credentials never leave either device.": { "zh-Hans": "同步额度快照与可选的每日汇总；服务商凭据始终留在各自设备上。", "zh-Hant": "同步額度快照與可選的每日彙總；服務商憑證始終留在各自裝置上。", ja: "上限スナップショットと任意の日次集計を同期します。プロバイダー認証情報はどちらのデバイスからも出ません。", ko: "한도 스냅샷과 선택적 일일 합계를 동기화하며 공급자 자격 증명은 각 기기를 벗어나지 않습니다.", es: "Sincroniza capturas de cuota y agregados diarios opcionales; las credenciales nunca salen de los dispositivos.", de: "Synchronisiert Kontingent-Snapshots und optionale Tageswerte; Anbieterzugangsdaten verlassen kein Gerät." },
  Paired: { "zh-Hans": "已配对", "zh-Hant": "已配對", ja: "ペアリング済み", ko: "페어링됨", es: "Emparejado", de: "Gekoppelt" },
  // The unpaired half of the Direct Sync status, plus the two states that
  // replace a timestamp before the first sync lands. "Paired" was translated
  // and these were not, so Devices showed one Chinese label beside two English
  // ones on the same row.
  "Not paired": { "zh-Hans": "未配对", "zh-Hant": "未配對", ja: "未ペアリング", ko: "페어링되지 않음", es: "Sin emparejar", de: "Nicht gekoppelt" },
  Waiting: { "zh-Hans": "等待中", "zh-Hant": "等待中", ja: "待機中", ko: "대기 중", es: "Esperando", de: "Wartet" },
  "Open Devices to pair": { "zh-Hans": "打开“设备”进行配对", "zh-Hant": "開啟「裝置」進行配對", ja: "「デバイス」を開いてペアリング", ko: "기기에서 페어링하세요", es: "Abre Dispositivos para emparejar", de: "Zum Koppeln „Geräte“ öffnen" },
  Address: { "zh-Hans": "地址", "zh-Hant": "位址", ja: "アドレス", ko: "주소", es: "Dirección", de: "Adresse" },
  Encryption: { "zh-Hans": "加密", "zh-Hant": "加密", ja: "暗号化", ko: "암호화", es: "Cifrado", de: "Verschlüsselung" },
  "Last sync": { "zh-Hans": "上次同步", "zh-Hant": "上次同步", ja: "最終同期", ko: "마지막 동기화", es: "Última sincronización", de: "Letzte Synchronisierung" },
  Disconnect: { "zh-Hans": "断开连接", "zh-Hant": "中斷連線", ja: "接続解除", ko: "연결 해제", es: "Desconectar", de: "Trennen" },
  "Mac address": { "zh-Hans": "Mac 地址", "zh-Hant": "Mac 位址", ja: "Mac アドレス", ko: "Mac 주소", es: "Dirección del Mac", de: "Mac-Adresse" },
  "One-time pairing code": { "zh-Hans": "一次性配对码", "zh-Hant": "一次性配對碼", ja: "ワンタイムペアリングコード", ko: "일회용 페어링 코드", es: "Código de emparejamiento único", de: "Einmaliger Kopplungscode" },
  "Shown in TokenRemain on Mac": { "zh-Hans": "显示在 Mac 版 TokenRemain 中", "zh-Hant": "顯示在 Mac 版 TokenRemain 中", ja: "Mac の TokenRemain に表示", ko: "Mac의 TokenRemain에 표시됨", es: "Se muestra en TokenRemain para Mac", de: "Wird in TokenRemain auf dem Mac angezeigt" },
  "Pair Mac": { "zh-Hans": "配对 Mac", "zh-Hant": "配對 Mac", ja: "Mac をペアリング", ko: "Mac 페어링", es: "Emparejar Mac", de: "Mac koppeln" },
  "Pairing…": { "zh-Hans": "正在配对…", "zh-Hant": "正在配對…", ja: "ペアリング中…", ko: "페어링 중…", es: "Emparejando…", de: "Kopplung…" },
  "Every enabled app is read on this PC first. Mac Direct Sync only fills a missing provider.": { "zh-Hans": "所有已启用应用都会优先在本机读取；Mac Direct Sync 只补充缺失的服务商。", "zh-Hant": "所有已啟用應用程式都會優先在本機讀取；Mac Direct Sync 只補充缺少的服務商。", ja: "有効なアプリはまずこの PC で読み取ります。Mac Direct Sync は不足するプロバイダーのみ補完します。", ko: "활성화된 앱은 먼저 이 PC에서 읽으며 Mac Direct Sync는 누락된 공급자만 보완합니다.", es: "Cada aplicación se lee primero en este PC; Mac Direct Sync solo completa proveedores ausentes.", de: "Jede aktivierte App wird zuerst auf diesem PC gelesen; Mac Direct Sync ergänzt nur fehlende Anbieter." },
  "Scan apps": { "zh-Hans": "扫描应用", "zh-Hant": "掃描應用程式", ja: "アプリをスキャン", ko: "앱 검색", es: "Buscar aplicaciones", de: "Apps suchen" },
  "Read from this app's existing Windows sign-in": { "zh-Hans": "读取此应用现有的 Windows 登录", "zh-Hant": "讀取此應用程式現有的 Windows 登入", ja: "このアプリの既存 Windows サインインを読み取り", ko: "이 앱의 기존 Windows 로그인에서 읽기", es: "Lee el inicio de sesión existente de esta aplicación en Windows", de: "Vorhandene Windows-Anmeldung dieser App lesen" },
  Local: { "zh-Hans": "本地", "zh-Hant": "本機", ja: "ローカル", ko: "로컬", es: "Local", de: "Lokal" },
  Detected: { "zh-Hans": "已检测", "zh-Hant": "已偵測", ja: "検出済み", ko: "감지됨", es: "Detectado", de: "Erkannt" },
  "Not found": { "zh-Hans": "未找到", "zh-Hant": "未找到", ja: "未検出", ko: "찾을 수 없음", es: "No encontrado", de: "Nicht gefunden" },
  Configured: { "zh-Hans": "已配置", "zh-Hant": "已設定", ja: "設定済み", ko: "구성됨", es: "Configurado", de: "Eingerichtet" },
  Setup: { "zh-Hans": "设置", "zh-Hant": "設定", ja: "設定", ko: "설정", es: "Configurar", de: "Einrichten" },
  Fallback: { "zh-Hans": "备用", "zh-Hant": "備援", ja: "フォールバック", ko: "대체", es: "Respaldo", de: "Fallback" },
  Optional: { "zh-Hans": "可选", "zh-Hant": "可選", ja: "任意", ko: "선택 사항", es: "Opcional", de: "Optional" },
  "No provider is enabled. Add one from Limits or scan this PC again.": { "zh-Hans": "尚未启用服务商。请从“额度”添加，或重新扫描本机。", "zh-Hant": "尚未啟用服務商。請從「額度」新增，或重新掃描本機。", ja: "プロバイダーが有効になっていません。「上限」から追加するか、この PC を再スキャンしてください。", ko: "활성화된 공급자가 없습니다. 한도에서 추가하거나 이 PC를 다시 검색하세요.", es: "No hay proveedores activados. Añade uno desde Cuotas o vuelve a analizar este PC.", de: "Kein Anbieter aktiviert. Unter Kontingente hinzufügen oder diesen PC erneut durchsuchen." },
  "Supporting sources": { "zh-Hans": "辅助数据源", "zh-Hant": "輔助資料來源", ja: "補助データソース", ko: "보조 데이터 소스", es: "Fuentes auxiliares", de: "Unterstützende Quellen" },
  "Usage history, pricing, feed, and optional cross-device fallback.": { "zh-Hans": "用量历史、价格、信息源及可选的跨设备备用数据。", "zh-Hant": "用量歷史、價格、資訊來源及可選的跨裝置備援資料。", ja: "使用履歴、価格、フィード、任意のデバイス間フォールバック。", ko: "사용 기록, 가격, 피드 및 선택적 기기 간 대체 데이터입니다.", es: "Historial de uso, precios, feed y respaldo opcional entre dispositivos.", de: "Nutzungsverlauf, Preise, Feed und optionaler geräteübergreifender Fallback." },
  "Local ccusage": { "zh-Hans": "本地 ccusage", "zh-Hant": "本機 ccusage", ja: "ローカル ccusage", ko: "로컬 ccusage", es: "ccusage local", de: "Lokales ccusage" },
  "Reads supported coding-agent logs on this PC; no separate ccusage install required": { "zh-Hans": "读取本机受支持编码代理的日志；无需单独安装 ccusage", "zh-Hant": "讀取本機受支援編碼代理的日誌；無需另行安裝 ccusage", ja: "この PC の対応エージェントログを読み取ります。ccusage の別途インストールは不要です", ko: "이 PC의 지원 코딩 에이전트 로그를 읽으며 ccusage를 별도로 설치할 필요가 없습니다", es: "Lee registros de agentes compatibles en este PC; no requiere instalar ccusage por separado", de: "Liest Protokolle unterstützter Coding-Agenten auf diesem PC; keine separate ccusage-Installation nötig" },
  "Public model pricing": { "zh-Hans": "公共模型价格", "zh-Hant": "公開模型價格", ja: "公開モデル価格", ko: "공개 모델 가격", es: "Precios públicos de modelos", de: "Öffentliche Modellpreise" },
  "%1$d validated model prices · refreshes every %2$d hours": { "zh-Hans": "%1$d 个已验证模型价格 · 每 %2$d 小时刷新", "zh-Hant": "%1$d 個已驗證模型價格 · 每 %2$d 小時重新整理", ja: "%1$d 件の検証済みモデル価格 · %2$d 時間ごとに更新", ko: "%1$d개 검증된 모델 가격 · %2$d시간마다 새로 고침", es: "%1$d precios validados · se actualiza cada %2$d h", de: "%1$d geprüfte Modellpreise · Aktualisierung alle %2$d Stunden" },
  "Using ccusage's embedded price table until the first public refresh": { "zh-Hans": "首次公共价格刷新前使用 ccusage 内置价格表", "zh-Hant": "首次公開價格重新整理前使用 ccusage 內建價格表", ja: "初回の公開更新までは ccusage 内蔵価格表を使用", ko: "첫 공개 새로 고침 전까지 ccusage 내장 가격표 사용", es: "Usando la tabla integrada de ccusage hasta la primera actualización pública", de: "Bis zur ersten öffentlichen Aktualisierung wird die ccusage-Preistabelle verwendet" },
  "%1$d provider fallbacks; Windows-local snapshots always win": { "zh-Hans": "%1$d 个服务商使用备用数据；Windows 本地快照始终优先", "zh-Hant": "%1$d 個服務商使用備援資料；Windows 本機快照始終優先", ja: "%1$d プロバイダーを補完中。Windows ローカルスナップショットを常に優先", ko: "%1$d개 공급자 대체 데이터 사용; Windows 로컬 스냅샷이 항상 우선", es: "%1$d proveedores con respaldo; las capturas locales de Windows siempre tienen prioridad", de: "%1$d Anbieter-Fallbacks; lokale Windows-Snapshots haben immer Vorrang" },
  "Optional fallback for providers missing on this PC, plus your Mac daily aggregate": { "zh-Hans": "可选补充本机缺失的服务商，以及 Mac 的每日汇总", "zh-Hant": "可選補充本機缺少的服務商，以及 Mac 的每日彙總", ja: "この PC にないプロバイダーと Mac の日次集計を任意で補完", ko: "이 PC에 없는 공급자와 Mac 일일 합계를 선택적으로 보완", es: "Respaldo opcional para proveedores ausentes y el agregado diario del Mac", de: "Optionaler Fallback für fehlende Anbieter plus Mac-Tageswerte" },
  "App sign-ins are read-only. Manually supplied keys and Cookies are encrypted with Windows credential protection; none are synced.": { "zh-Hans": "应用登录仅以只读方式访问。手动提供的密钥与 Cookie 受 Windows 凭据保护加密，且不会同步。", "zh-Hant": "應用程式登入僅以唯讀方式存取。手動提供的金鑰與 Cookie 受 Windows 憑證保護加密，且不會同步。", ja: "アプリのサインインは読み取り専用です。手動入力したキーと Cookie は Windows 資格情報保護で暗号化され、同期されません。", ko: "앱 로그인은 읽기 전용입니다. 직접 입력한 키와 Cookie는 Windows 자격 증명 보호로 암호화되며 동기화되지 않습니다.", es: "Los inicios de sesión son de solo lectura. Las claves y cookies se cifran con la protección de credenciales de Windows y no se sincronizan.", de: "App-Anmeldungen werden nur gelesen. Manuelle Schlüssel und Cookies sind durch Windows-Anmeldedatenschutz verschlüsselt und werden nicht synchronisiert." },
  "Built-in ccusage reads local agent logs offline; raw sessions, prompts, paths, and repository names never leave this PC.": { "zh-Hans": "内置 ccusage 离线读取本地代理日志；原始会话、提示词、路径和仓库名称绝不会离开本机。", "zh-Hant": "內建 ccusage 離線讀取本機代理日誌；原始工作階段、提示詞、路徑和儲存庫名稱絕不會離開本機。", ja: "内蔵 ccusage はローカルログをオフラインで読み取ります。生のセッション、プロンプト、パス、リポジトリ名はこの PC から出ません。", ko: "내장 ccusage는 로컬 에이전트 로그를 오프라인으로 읽으며 원시 세션, 프롬프트, 경로, 저장소 이름은 이 PC를 벗어나지 않습니다.", es: "ccusage lee registros locales sin conexión; sesiones, prompts, rutas y repositorios nunca salen de este PC.", de: "Das integrierte ccusage liest lokale Agentenprotokolle offline; Sitzungen, Prompts, Pfade und Repository-Namen verlassen diesen PC nie." },
  "Only the complete public LiteLLM price table is downloaded. No observed model name, token count, or usage-derived query is sent.": { "zh-Hans": "只下载完整的公共 LiteLLM 价格表；不会发送观测到的模型名、token 数量或任何基于用量的查询。", "zh-Hant": "只下載完整的公開 LiteLLM 價格表；不會傳送觀測到的模型名稱、token 數量或任何依用量產生的查詢。", ja: "完全な公開 LiteLLM 価格表のみをダウンロードします。観測したモデル名、トークン数、使用量由来の照会は送信しません。", ko: "전체 공개 LiteLLM 가격표만 다운로드하며 관찰된 모델명, 토큰 수 또는 사용량 기반 쿼리는 전송하지 않습니다.", es: "Solo se descarga la tabla pública completa de LiteLLM; no se envían modelos observados, tokens ni consultas derivadas del uso.", de: "Nur die vollständige öffentliche LiteLLM-Preistabelle wird geladen; Modellnamen, Tokenzahlen und nutzungsbezogene Abfragen werden nicht gesendet." },
  "Direct Sync optionally exchanges AES-256-GCM encrypted quota snapshots and daily aggregates with your Mac, but remote quota is fallback-only.": { "zh-Hans": "Direct Sync 可选择与 Mac 交换 AES-256-GCM 加密的额度快照和每日汇总，但远端额度只作备用。", "zh-Hant": "Direct Sync 可選擇與 Mac 交換 AES-256-GCM 加密的額度快照和每日彙總，但遠端額度只作備援。", ja: "Direct Sync は AES-256-GCM 暗号化された上限スナップショットと日次集計を Mac と任意で交換しますが、リモート上限は補完専用です。", ko: "Direct Sync는 AES-256-GCM으로 암호화된 한도 스냅샷과 일일 합계를 Mac과 선택적으로 교환하며 원격 한도는 대체용입니다.", es: "Direct Sync puede intercambiar capturas y agregados diarios cifrados con AES-256-GCM; la cuota remota solo sirve de respaldo.", de: "Direct Sync tauscht optional AES-256-GCM-verschlüsselte Snapshots und Tageswerte mit dem Mac aus; Remote-Kontingente dienen nur als Fallback." },
  "No CloudKit and no phone sync in this Windows build.": { "zh-Hans": "此 Windows 版本不使用 CloudKit，也不与手机同步。", "zh-Hant": "此 Windows 版本不使用 CloudKit，也不與手機同步。", ja: "この Windows ビルドでは CloudKit とスマートフォン同期を使用しません。", ko: "이 Windows 빌드는 CloudKit 및 휴대폰 동기화를 사용하지 않습니다.", es: "Esta versión de Windows no usa CloudKit ni sincronización con el teléfono.", de: "Dieser Windows-Build verwendet weder CloudKit noch Smartphone-Synchronisierung." },
  "Quota is being read with the credential protected on this PC": { "zh-Hans": "正使用受本机保护的凭据读取额度", "zh-Hant": "正使用受本機保護的憑證讀取額度", ja: "この PC で保護された認証情報を使って上限を読み取り中", ko: "이 PC에서 보호된 자격 증명으로 한도 읽는 중", es: "Leyendo la cuota con la credencial protegida en este PC", de: "Kontingent wird mit geschützten Zugangsdaten dieses PCs gelesen" },
  "Save locally": { "zh-Hans": "保存到本机", "zh-Hant": "儲存到本機", ja: "ローカルに保存", ko: "로컬 저장", es: "Guardar localmente", de: "Lokal speichern" },
  "Percentages show the remaining quota within a window; usage-based services show the remaining monetary balance directly. Windows come from each provider's servers: Claude, Codex, and Z.ai usually include a 5-hour session window and a 7-day window; Cursor uses a monthly billing window; Grok uses a weekly pool.": { "zh-Hans": "百分比表示窗口内的剩余额度；按量计费服务会直接显示剩余金额。窗口数据来自各服务商服务器：Claude、Codex 和 Z.ai 通常包含 5 小时会话窗口和 7 天窗口；Cursor 使用月度计费窗口；Grok 使用每周额度池。", "zh-Hant": "百分比表示視窗內的剩餘額度；按量計費服務會直接顯示剩餘金額。視窗資料來自各服務商伺服器：Claude、Codex 和 Z.ai 通常包含 5 小時工作階段視窗和 7 天視窗；Cursor 使用月度計費視窗；Grok 使用每週額度池。", ja: "割合はウィンドウ内の残り上限を示し、従量制サービスは残高を直接表示します。ウィンドウは各プロバイダーのサーバー由来です。Claude、Codex、Z.ai は通常 5 時間と 7 日、Cursor は月次、Grok は週次の枠を使用します。", ko: "백분율은 창의 남은 한도를 나타내며 사용량 기반 서비스는 남은 금액을 직접 표시합니다. 창은 각 공급자 서버에서 가져옵니다. Claude, Codex, Z.ai는 보통 5시간 및 7일 창, Cursor는 월간 창, Grok은 주간 풀을 사용합니다.", es: "Los porcentajes muestran la cuota restante; los servicios por uso muestran el saldo. Las ventanas provienen de cada proveedor: Claude, Codex y Z.ai suelen tener ventanas de 5 horas y 7 días; Cursor usa una mensual y Grok una semanal.", de: "Prozentwerte zeigen das verbleibende Kontingent; nutzungsbasierte Dienste direkt den Geldbetrag. Die Fenster stammen von den Anbieterservern: Claude, Codex und Z.ai meist 5 Stunden und 7 Tage, Cursor monatlich, Grok wöchentlich." },
};

const WINDOWS_KEY_MESSAGES = {
  "time.now": { en: "now", "zh-Hans": "刚刚", "zh-Hant": "剛剛", ja: "たった今", ko: "방금", es: "ahora", de: "gerade eben" },
  "feed.age.hours_minutes": { en: "%1$d hr, %2$d min", "zh-Hans": "%1$d小时 %2$d分", "zh-Hant": "%1$d小時 %2$d分", ja: "%1$d時間 %2$d分", ko: "%1$d시간 %2$d분", es: "%1$d h, %2$d min", de: "%1$d Std., %2$d Min." },
  "feed.age.days_hours": { en: "%1$d d, %2$d hr", "zh-Hans": "%1$d天 %2$d小时", "zh-Hant": "%1$d天 %2$d小時", ja: "%1$d日 %2$d時間", ko: "%1$d일 %2$d시간", es: "%1$d d, %2$d h", de: "%1$d T., %2$d Std." },
  "usage.snapshot_note": { "zh-Hans": "以上为今日快照；跨天趋势请查看“趋势”。", "zh-Hant": "以上為今日快照；跨日趨勢請查看「趨勢」。" },
  // The shared catalog's hint names the macOS menu bar and Dock, neither of
  // which exists here; on Windows the same three surfaces are the tray, Quick
  // View, and the Dashboard. English is overridden too, so the source copy is
  // right on this platform rather than only its translations.
  "settings.quota_summary_hint": {
    en: "Choose which account-level quota window the tray, Quick View, and Dashboard summaries prioritize; model-specific quotas stay excluded.",
    "zh-Hans": "选择托盘、快速查看与 Dashboard 摘要优先显示哪个账号级额度窗口；模型专属额度不参与。",
    "zh-Hant": "選擇系統匣、快速檢視與 Dashboard 摘要優先顯示哪個帳號級額度視窗；模型專屬額度不參與。",
    ja: "トレイ、クイックビュー、Dashboard の概要でどのアカウント単位の上限ウィンドウを優先するかを選びます。モデル固有の上限は対象外です。",
    ko: "트레이, 빠른 보기, Dashboard 요약에서 우선할 계정 단위 한도 창을 선택합니다. 모델별 한도는 제외됩니다.",
    es: "Elige qué ventana de cuota de cuenta priorizan la bandeja, la vista rápida y los resúmenes del Dashboard; las cuotas por modelo quedan excluidas.",
    de: "Wähle, welches kontobezogene Kontingentfenster im Infobereich, in der Schnellansicht und in den Dashboard-Zusammenfassungen bevorzugt wird; modellspezifische Kontingente bleiben ausgenommen.",
  },
  // Separates the per-provider readings inside the floating shortcut's
  // accessible name, where CJK screen readers expect their own enumeration mark.
  "floating.provider_separator": { en: ", ", "zh-Hans": "，", "zh-Hant": "，", ja: "、", ko: ", ", es: ", ", de: ", " },
};

const englishKeysByValue = new Map(Object.entries(catalogs.en).map(([key, value]) => [value, key]));
let activeLanguage = "en";

export function normalizeLanguage(value) {
  const raw = String(value || "").replaceAll("_", "-");
  const lower = raw.toLowerCase();
  if (lower === "system") return SYSTEM_LANGUAGE;
  if (lower.startsWith("zh-hant") || /^zh-(tw|hk|mo)(-|$)/.test(lower)) return "zh-Hant";
  if (lower.startsWith("zh")) return "zh-Hans";
  return SUPPORTED_LANGUAGES.find((locale) => locale.toLowerCase() === lower || locale.split("-")[0] === lower.split("-")[0]) || "en";
}

export function resolveLanguage(preference = SYSTEM_LANGUAGE, systemLocale, browserLanguages = globalThis.navigator?.languages || []) {
  if (preference && preference !== SYSTEM_LANGUAGE) return normalizeLanguage(preference);
  for (const candidate of [systemLocale, ...browserLanguages]) {
    if (!candidate) continue;
    const normalized = normalizeLanguage(candidate);
    if (normalized !== "en" || String(candidate).toLowerCase().startsWith("en")) return normalized;
  }
  return "en";
}

export function activateLanguage(preference, systemLocale) {
  activeLanguage = resolveLanguage(preference, systemLocale);
  if (globalThis.document?.documentElement) {
    globalThis.document.documentElement.lang = activeLanguage;
    globalThis.document.documentElement.dir = "ltr";
  }
  return activeLanguage;
}

export function getActiveLanguage() {
  return activeLanguage;
}

function interpolate(value, argumentsList) {
  let implicit = 0;
  return String(value).replace(/%(?:(\d+)\$)?(?:\.\d+)?(?:@|d|f)/g, (_match, explicit) => {
    const index = explicit ? Number(explicit) - 1 : implicit++;
    return argumentsList[index] ?? "";
  });
}

export function tr(source, argumentsList = []) {
  if (source === undefined || source === null) return "";
  const override = WINDOWS_MESSAGES[source]?.[activeLanguage];
  const key = englishKeysByValue.get(source);
  const localized = override || (key ? catalogs[activeLanguage]?.[key] : undefined) || source;
  return interpolate(localized, Array.isArray(argumentsList) ? argumentsList : [argumentsList]);
}

export function trKey(key, argumentsList = [], fallback = key) {
  const windowsValue = WINDOWS_KEY_MESSAGES[key]?.[activeLanguage];
  return interpolate(windowsValue || catalogs[activeLanguage]?.[key] || catalogs.en[key] || fallback, Array.isArray(argumentsList) ? argumentsList : [argumentsList]);
}

export function languageOptions(systemLocale) {
  const detected = resolveLanguage(SYSTEM_LANGUAGE, systemLocale);
  return [
    { value: SYSTEM_LANGUAGE, label: `${tr("System default")} · ${LANGUAGE_NAMES[detected]}` },
    ...SUPPORTED_LANGUAGES.map((value) => ({ value, label: LANGUAGE_NAMES[value] })),
  ];
}
