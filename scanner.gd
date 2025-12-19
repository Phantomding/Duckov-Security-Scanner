extends Control


# 🚫 违禁品名单 (Native API)
# 正常的 C# Mod 绝不需要直接调用这些 Windows 底层函数
# 如果出现了，说明它想绕过游戏引擎干坏事（读写内存、注入病毒、执行CMD）
var forbidden_imports = {
	"KERNEL32.dll": 50,  # 操作内存/进程的核心库
	"USER32.dll": 30,    # 监控键盘/鼠标
	"SHELL32.dll": 80,   # 执行系统命令 (cmd/powershell)
	"ADVAPI32.dll": 60,  # 修改注册表
	"VirtualProtect": 100, # 修改内存权限 (典型的病毒注入行为)
	"WriteProcessMemory": 100, # 修改游戏内存 (外挂/病毒特征)
	"GetProcAddress": 80, # 动态获取函数地址 (躲避静态查杀的常用手段)
	"InternetOpen": 60   # 底层联网 (非Unity联网)
}

# ================= 配置区域 =================

# 1. 威胁评分规则 (正则 : 分数)
# 分数越高越危险。
# 正则说明：(?!schemas) 是为了防止 xml 文件头里的 http 误报
# === 优化后的规则库 v1.2 ===
var risk_rules = {
	# --- 1. 进程与系统操作 (精准打击) ---
	# "System\\.Diagnostics": 5,  <-- 删除！太容易误伤计时器等功能
	"Process\\.Start": 25,        # 启动外部程序 (比如悄悄运行一个 .bat 或 .exe)
	"Application\\.Quit": 100,    # 强制退出游戏 (逻辑炸弹核心)
	"Environment\\.Exit": 100,    # 另一种强制退出

	# --- 2. 敏感文件操作 ---
	"File\\.Delete": 30,          # 删除文件 (正常Mod很少需要删文件)
	"Directory\\.Delete": 30,     # 删除文件夹
	"File\\.Copy": 10,            # 复制/覆盖文件 (可能是篡改)
	
	# --- 3. 网络行为 (区分“浏览”和“偷窃”) ---
	# "System\\.Net": 5,          <-- 删除！只要联网就报毒太蠢了
	"WebClient\\.Upload": 50,     # 上传数据 (偷隐私嫌疑大)
	"HttpClient\\.Post": 30,      # 发送 POST 请求 (可能在上传)
	"DownloadFile": 20,           # 下载文件 (如果是下载 exe 则是高危)
	
	# --- 4. 动态代码执行 (后门特征) ---
	"Assembly\\.Load": 60,        # 动态加载二进制代码 (极度危险，类似远程控制)
	"System\\.Reflection": 10,    # 反射 (正常Mod也会用，权重给低点，仅作提示)

	# --- 5. 针对性恶意特征 ---
	"SteamID": 40,                # 配合 Quit 使用通常是炸弹
	"CheckSteamUID": 60,          # 恶意函数名特征
	"3600714295": 1000            # 已知的恶意作者ID
}

# 2. 白名单指纹库 (文件名 : [合法的MD5列表])
# 如果你的扫描器以后报错了正版文件，先用 get_md5() 获取它的哈希，填入这里
var safe_file_hashes = {
	"0Harmony.dll": [
		"2afc09f2cd4cba05d85cc7c4f7d62edb", 
		"如果有多个版本可以填第二行" 
	],
	"BepInEx.dll": [
		"这里填入正版BepInEx的MD5"
	],
}


# 🚫 黑名单指纹库 (已知的病毒文件 MD5)
# 只要碰到这个指纹，不管叫什么名字，直接报毒
var dangerous_file_hashes = [
	# 这里填入 RandomNpc.dll 的 MD5 (你可以用扫描器打印出来获取)
	"这里填入你扫描出的RandomNpc的MD5值" ,
	""
]

# 3. 忽略的大文件阈值 (字节)
const MAX_FILE_SIZE = 50 * 1024 * 1024 # 50MB

# ===========================================

@onready var status_label = $StatusLabel
@onready var result_container = $ResultList/VBoxContainer
@onready var mascot = $Mascot

# 缓存编译好的正则对象
var compiled_rules = {}

# === 1. 初始化界面 (版本号 + 免责声明) ===
func _ready():
	# A. 设置窗口标题和版本号
	DisplayServer.window_set_title("Duckov Security Scanner v1.0.1 (Beta)")
	
	# B. 动态添加免责声明 (在窗口底部生成一行小字)
	var disclaimer = Label.new()
	disclaimer.text = "免责声明: 本工具基于社区已知特征开发，不能保证 100% 拦截未知病毒。删除文件前请务必备份。"
	disclaimer.add_theme_font_size_override("font_size", 12) # 字体设小一点
	disclaimer.modulate = Color(1, 1, 1, 0.5) # 半透明，不抢眼
	
	# 把它放到屏幕底部居中
	disclaimer.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	disclaimer.position.y -= 10 # 往上提一点点
	add_child(disclaimer)

	# C. 原有的初始化逻辑
	get_tree().get_root().files_dropped.connect(_on_files_dropped)
	
	# 预编译正则
	for pattern in risk_rules:
		var regex = RegEx.new()
		regex.compile(pattern)
		compiled_rules[pattern] = regex
		
	status_label.text = "安全终端就绪。请拖入 Mod 文件夹..."
	status_label.modulate = Color.WHITE

func _on_files_dropped(files):
	var folder_path = files[0]
	var dir = DirAccess.open(folder_path)
	if dir:
		start_scan(folder_path)
	else:
		status_label.text = "错误：请拖入一个有效的文件夹！"
		status_label.modulate = Color.RED

func start_scan(path):
	# === 初始化 UI ===
	for child in result_container.get_children():
		child.queue_free()
	
	status_label.text = "正在初始化扫描引擎..."
	status_label.modulate = Color.YELLOW
	await get_tree().create_timer(0.3).timeout # 稍微停顿，增加仪式感
	
	# === 获取所有文件 ===
	var all_files = get_all_files(path)
	if all_files.size() == 0:
		status_label.text = "文件夹为空或无法读取！"
		return

	# === 开始循环扫描 ===
	var issues_found = 0
	var scanned_count = 0
	
	for file_path in all_files:
		# === 🆕 插入点：优先检查 info.ini ===
		if file_path.get_file() == "info.ini":
			var is_banned = check_info_ini(file_path)
			if is_banned:
				issues_found += 1
				print("🔴 发现封禁 ID: " + file_path)
				continue # 如果确定是坏的，这个文件就不用往下扫了
		# ===================================
		scanned_count += 1
		
		# 每扫描5个文件刷新一次界面，防止卡死
		if scanned_count % 5 == 0:
			status_label.text = "正在分析 (%d/%d): %s" % [scanned_count, all_files.size(), file_path.get_file()]
			await get_tree().process_frame
		
		# --- 核心扫描逻辑 ---
		var result = scan_single_file(file_path)
		var score = result["score"]
		
		# --- 结果判定 (红绿灯机制) ---
		if score >= 50:
			# 🔴 红色高危
			issues_found += 1
			add_alert_card(file_path.get_file(), result["details"], Color.RED, score)
			print("🔴 高危发现: " + file_path.get_file())
			
		elif score >= 20:
			# 🟡 黄色可疑
			issues_found += 1
			add_alert_card(file_path.get_file(), result["details"], Color.ORANGE, score)
			print("🟡 可疑文件: " + file_path.get_file())
			
		else:
			# 🟢 绿色/灰色 (分数很低，忽略)
			# print("🟢 安全/噪音: " + file_path.get_file() + " 分数: " + str(score))
			pass

	# === 最终结算 ===
	if issues_found == 0:
		status_label.text = "扫描完成：所有文件安全！(✅)"
		status_label.modulate = Color.GREEN
		# mascot.texture = load("res://happy_duck.png") # 如果你有图片的话
	else:
		status_label.text = "警告：发现 %d 个潜在威胁！请检查列表。" % issues_found
		status_label.modulate = Color.RED
		# mascot.texture = load("res://angry_duck.png")

# --- 辅助功能：递归获取文件 ---
func get_all_files(path: String) -> Array:
	var files = []
	var dir = DirAccess.open(path)
	if dir:
		dir.list_dir_begin()
		var file_name = dir.get_next()
		while file_name != "":
			if dir.current_is_dir():
				if file_name != "." and file_name != "..":
					files.append_array(get_all_files(path + "/" + file_name))
			else:
				files.append(path + "/" + file_name)
			file_name = dir.get_next()
	return files

# --- 核心功能：清洗二进制乱码 ---
func extract_readable_text(raw_bytes: PackedByteArray) -> String:
	var safe_bytes = PackedByteArray()
	for b in raw_bytes:
		# 只保留 ASCII 可打印字符 (32-126) 以及 换行符
		if (b >= 32 and b <= 126) or b == 10 or b == 13:
			safe_bytes.append(b)
	return safe_bytes.get_string_from_ascii()

func scan_single_file(path: String) -> Dictionary:
	var file_obj = FileAccess.open(path, FileAccess.READ)
	if not file_obj: return {"score": 0, "details": []}
	
	var file_len = file_obj.get_length()
	if file_len == 0: return {"score": 0, "details": []}
	if file_len > MAX_FILE_SIZE: return {"score": 0, "details": []}
	
	var file_name = path.get_file()
	var current_score = 0
	var found_details = []
	
	# === 1. 读取并清洗 ===
	var content_bytes = file_obj.get_buffer(file_len)
	var content_cleaned = extract_readable_text(content_bytes)
	var is_dll = path.get_extension().to_lower() == "dll"
	
	# === 2. 结构与伪装检查 (The Structure Check) ===
	if is_dll:
		# --- 身份验证 ---
		var has_dotnet_magic = "BSJB" in content_cleaned
		
		# --- 伪装检测 ---
		if not has_dotnet_magic:
			current_score += 100
			# [话术优化] 语气客观陈述事实
			found_details.append("⚠️ 架构异常: 缺失 .NET 签名 (BSJB)")
			found_details.append("   └─ 分析: 这是一个原生(Native)程序，而非标准的 C# Mod。请确认来源。")
		else:
			# --- 混淆/可读性检测 ---
			var valid_markers = ["UnityEngine", "Assembly-CSharp", "BepInEx", "0Harmony", "System.Runtime", "mscorlib", "System"]
			var looks_like_unity_mod = false
			for marker in valid_markers:
				if marker in content_cleaned:
					looks_like_unity_mod = true
					break
			
			var readability_ratio = float(content_cleaned.length()) / float(file_len)
			
			# [阈值微调] 稍微降低一点敏感度，避免误伤极简Mod
			if not looks_like_unity_mod and readability_ratio < 0.01: 
				current_score += 80
				found_details.append("⚠️ 混淆疑虑: 文件可读信息密度极低 (%.2f%%)" % (readability_ratio * 100))
				found_details.append("   └─ 提示: 无法识别常见Mod特征，疑似加壳或加密。")

			# --- 违禁品搜身 (Harmony 豁免逻辑保持不变) ---
			var is_real_harmony = "harmony" in file_name.to_lower() and ("Harmony" in content_cleaned or "0Harmony" in content_cleaned)
			
			for bad_api in forbidden_imports:
				if bad_api in content_cleaned:
					if is_real_harmony and bad_api in ["VirtualProtect", "GetProcAddress", "KERNEL32.dll", "LoadLibrary"]:
						continue # 豁免
					
					current_score += forbidden_imports[bad_api]
					# [话术优化] 强调是“底层调用”而不是“违禁品”
					found_details.append("⚙️ 底层调用检测: %s" % bad_api)
					
					if looks_like_unity_mod and not is_real_harmony:
						current_score += 40 # 稍微降分
						found_details.append("   └─ 警告: 普通Mod通常不需要调用此系统内核接口。")

	# === 3. 行为逻辑特征扫描 (使用新规则库) ===
	for pattern in compiled_rules:
		var regex = compiled_rules[pattern]
		var match = regex.search(content_cleaned)
		if match:
			var weight = risk_rules[pattern]
			current_score += weight
			
			var display_name = pattern.replace("\\", "")
			# [话术优化] 使用“行为”而非“威胁”
			found_details.append("🔍 敏感行为: %s (+%d)" % [display_name, weight])
			
			# 针对高危项的特殊提示
			if "Quit" in display_name or "Exit" in display_name:
				found_details.append("   └─ 🔴 高危: 包含强制退出游戏代码 (逻辑炸弹特征)")
			elif "SteamID" in display_name:
				found_details.append("   └─ 🟠 隐私: 包含读取 SteamID 的逻辑 (可能用于鉴权或黑名单)")
			elif "Process.Start" in display_name:
				found_details.append("   └─ 🟠 警告: 试图启动外部进程 (如打开网页或运行其他程序)")
			elif "Upload" in display_name:
				found_details.append("   └─ 🟠 警告: 试图上传数据到网络")

	return {
		"score": current_score,
		"details": found_details
	}
	
# --- UI功能：生成警告卡片 ---
func add_alert_card(filename, details, color, score):
	var card = Label.new()
	# 组装提示文字
	var text = "⚠️ %s [危险指数: %d]\n" % [filename, score]
	for d in details:
		text += "   └─ 发现: %s\n" % d
		
	card.text = text
	card.modulate = color
	result_container.add_child(card)
	# 加个分隔线
	var separator = HSeparator.new()
	result_container.add_child(separator)

# === 3. 特攻检测：扫描 info.ini ===
func check_info_ini(path: String) -> bool:
	var f = FileAccess.open(path, FileAccess.READ)
	if not f: return false
	
	var content = f.get_as_text()
	# 官方实锤封禁的恶意 Mod ID
	if "3600714295" in content:
		add_alert_card("info.ini", [
			"🛑 官方封禁追杀令",
			"   └─ 检测到 Mod ID: 3600714295",
			"   └─ 结论: 这就是那个会导致闪退的恶意 Scav Mod，请立即删除！"
		], Color.RED, 9999) # 分数给极高，置顶显示
		return true # 发现问题
	return false
