extends Control

# === 🦆 Duckov Mod Inspector v1.3 核心配置 ===
const MAX_FILE_SIZE = 20 * 1024 * 1024 # 20MB 限制
var compiled_risk_rules = {}
var is_scanning = false # 🔒 扫描锁：防止重复拖拽导致卡死
# 节点引用 (根据你刚才修改的结构)
@onready var status_label = $StatusLabel
# 这里路径对应：MainScanner -> ResultScroll -> ResultText
@onready var result_text = $ResultScroll/ResultText 

# 1. ℹ️ 能力透视 (Capabilities) - 中性描述
var capability_rules = {
	"System\\.Net": "基础网络访问 (System.Net)",
	"UnityWebRequest": "HTTP 联网能力 (UnityWebRequest)",
	"Socket": "Socket 长连接 (聊天/联机)",
	"System\\.IO": "文件读写操作 (System.IO)",
	"File\\.Write": "写入/修改文件",
	"File\\.Delete": "删除文件",
	"Directory\\.Delete": "删除文件夹",
	"PlayerPrefs": "读写游戏配置/注册表",
	"Discord": "Discord SDK 集成",
	"Steamworks": "Steam API 集成"
}

# 2. 🚨 风险行为 (Risks) - 针对二进制拆解优化
# 格式: "正则关键词": [分数, "显示的警告文本"]
var risk_rules = {
	# --- 🔴 极度高危 (逻辑炸弹) ---
	"Environment\\.Exit": [100, "🔴 进程查杀: 包含强制终止进程代码 (Environment.Exit)"],
	"3600714295": [1000, "🔴 黑名单: 已知恶意作者 ID"],
	
	# --- 🟠 高危行为 (拆解后的关键词，防止漏报) ---
	# v1.3.1 修复: DLL中类名和方法名是分开存的，必须单搜 "Quit"
	"Quit": [60, "🟠 退出逻辑: 发现 'Quit' 关键词 (可能包含 Application.Quit)"],
	
	# v1.3.1 修复: 针对 SteamID 的各种变形
	"SteamId": [80, "🟠 身份读取: 发现 'SteamId' 属性引用"],
	"CSteamID": [80, "🟠 身份读取: 发现 'CSteamID' 底层结构"],
	"GetSteamID": [80, "🟠 身份读取: 发现获取 SteamID 的函数调用"],
	
	# --- 🟠 敏感操作 ---
	"Process\\.Start": [40, "🟠 外部进程: 试图启动外部 EXE"],
	"WebClient": [50, "🟠 网络组件: 发现 WebClient 引用"],
	"HttpClient": [50, "🟠 网络组件: 发现 HttpClient 引用"],
	"UploadString": [50, "🟠 数据上传: 发现上传字符串的代码"],
	"UploadData": [50, "🟠 数据上传: 发现上传数据的代码"],
	"Assembly\\.Load": [60, "🟠 动态加载: 试图加载二进制代码"],
	
	# --- 🟡 敏感 (Harmony豁免项) ---
	"VirtualProtect": [20, "🟡 底层操作: 修改内存权限"],
	"GetProcAddress": [20, "🟡 底层操作: 动态获取API地址"],
	"KERNEL32": [20, "🟡 底层操作: 调用 Windows 内核 API"]
}

func _ready():
	DisplayServer.window_set_title("Duckov Mod Inspector v1.3")
	
	# 编译正则
	for pattern in risk_rules:
		var regex = RegEx.new()
		regex.compile(pattern)
		compiled_risk_rules[pattern] = regex
	
	# 连接全屏拖拽信号
	get_viewport().files_dropped.connect(_on_files_dropped)
	
	status_label.text = "将 Mod (.dll) 拖入此处开始审计"
	result_text.text = "[color=#888888]等待文件...[/color]"

func _on_files_dropped(files):
	# 🔒 1. 如果正在忙，直接忽略这次拖拽，防止卡死叠加
	if is_scanning:
		status_label.text = "⚠️ 正在忙，请稍后..."
		return

	is_scanning = true # 上锁
	result_text.text = "" # 清空旧结果
	
	var total_score = 0
	var full_report = ""
	var all_target_files = []
	
	# === 第一阶段：收集文件 (快速) ===
	status_label.text = "正在分析文件列表..."
	await get_tree().process_frame # 强制刷新UI
	
	for path in files:
		if DirAccess.dir_exists_absolute(path):
			# 如果是文件夹，获取里面所有dll
			all_target_files.append_array(get_all_files(path, ["dll"]))
		else:
			# 如果是单文件
			if path.get_extension().to_lower() == "dll":
				all_target_files.append(path)
	
	var total_count = all_target_files.size()
	var scanned_count = 0
	
	# === 第二阶段：逐个扫描 (慢速，需要呼吸) ===
	if total_count == 0:
		result_text.text = "[color=yellow]❌ 未找到可审计的文件 (仅支持 .dll)[/color]"
		status_label.text = "就绪"
		is_scanning = false
		return

	for file_path in all_target_files:
		scanned_count += 1
		
		# 💡 UI 交互优化：实时告诉用户进度
		status_label.text = "正在审计: %d / %d" % [scanned_count, total_count]
		
		# 💡 防卡死核心：每处理 5 个文件，就暂停一帧，让 UI 喘口气
		if scanned_count % 5 == 0:
			await get_tree().process_frame
			
		# 👇👇👇 关键修改点：加了 await 👇👇👇
		var result = await scan_single_file(file_path)
		
		# 只有有发现才记录
		if result["score"] > 0 or result["details"].size() > 0:
			total_score += result["score"]
			full_report += "\n[b]📄 文件: %s[/b]\n" % file_path.get_file()
			for line in result["details"]:
				full_report += line + "\n"
			full_report += "[color=#444444]--------------------------------[/color]\n"

	# === 第三阶段：生成报告 ===
	var summary = ""
	if total_score >= 50:
		summary = "[color=red][b]🚫 高危警告 (风险分: %d)[/b][/color]\n发现明确的敏感权限特征，请在确认安全的情况下使用。\n" % total_score
	elif total_score > 0:
		summary = "[color=orange][b]⚠️ 需人工审查 (风险分: %d)[/b][/color]\n发现敏感操作，请查阅下方详情。\n" % total_score
	else:
		summary = "[color=#44ff44][b]✅ 未发现已知风险[/b][/color]\n(但这不代表绝对安全，请参考下方的能力透视)\n"
	
	if full_report == "":
		full_report = "\n[i]未检测到任何敏感行为或特殊能力 API 调用。[/i]"
		
	result_text.text = summary + full_report
	status_label.text = "审计完成 (共扫描 %d 个文件)" % scanned_count
	
	is_scanning = false # 🔓 解锁
	
# === 扫描引擎 ===
# === 核心：单文件扫描引擎 v1.3.1 ===
func scan_single_file(path: String) -> Dictionary:
	var file_obj = FileAccess.open(path, FileAccess.READ)
	if not file_obj: return {"score": 0, "details": []}
	
	var file_len = file_obj.get_length()
	# 防卡死/防溢出检查 (20MB)
	if file_len == 0 or file_len > MAX_FILE_SIZE: 
		return {"score": 0, "details": ["[color=yellow]⚠️ 跳过: 文件过大 (>20MB) 或为空[/color]"]}
	
	var file_name = path.get_file()
	var current_score = 0
	var report_lines = [] 
	
	# 1. 读取并清洗内容 (使用异步流式清洗，防止截断和卡死)
	var content_bytes = file_obj.get_buffer(file_len)
	# 👇 关键: 必须使用 await 等待清洗完成
	var content_cleaned = await extract_readable_text_async(content_bytes)
	
	var is_dll = path.get_extension().to_lower() == "dll"
	
	# 2. 基础架构检查 (Architecture)
	if is_dll:
		# 检查 .NET 签名 BSJB
		if not "BSJB" in content_cleaned:
			current_score += 100
			report_lines.append("[color=red]🛑 [架构] 异常: 原生(Native)程序伪装成 Mod (Scav 1.5 特征)[/color]")
		
		# Harmony 特权判定
		var is_real_harmony = "harmony" in file_name.to_lower() and ("Harmony" in content_cleaned or "0Harmony" in content_cleaned)
		if is_real_harmony:
			report_lines.append("[color=green]🛡️ [架构] 识别为 Harmony 补丁库 (已豁免底层内存操作)[/color]")

	# 3. 能力透视 (Capabilities) - 中性展示
	var capabilities_found = []
	for keyword in capability_rules:
		if keyword in content_cleaned:
			var desc = capability_rules[keyword]
			if not desc in capabilities_found:
				capabilities_found.append(desc)
	
	if capabilities_found.size() > 0:
		report_lines.append("[color=#88ccff]⚡ [能力透视] 该 Mod 具备以下能力:[/color]")
		for cap in capabilities_found:
			report_lines.append("   └─ %s" % cap)

	# 4. 风险检测 (Risks) - 计分
	for pattern in compiled_risk_rules:
		var regex = compiled_risk_rules[pattern]
		
		# 使用正则搜索
		if regex.search(content_cleaned):
			var rule_data = risk_rules[pattern]
			var weight = rule_data[0]
			var desc = rule_data[1]
			
			# --- 特殊逻辑：Quit 智能消噪 v1.3.1 ---
			# 如果搜到了 "Quit"，为了防止误报普通单词 (如 Quite)，
			# 我们这里做一个简单的单词边界检查 (虽然正则里也可以做，但代码里更灵活)
			if pattern == "Quit":
				# 如果内容里只是 "Quite" 或 "Equity"，regex 可能会误判（取决于是否用了 \b）
				# 这里我们信任上面的正则规则，但如果想更保险，可以检查是否包含 UnityEngine
				pass 

			# --- 特权豁免逻辑 ---
			# 只有 Harmony 允许调用 VirtualProtect/GetProcAddress/KERNEL32
			var is_memory_op = "VirtualProtect" in pattern or "GetProcAddress" in pattern or "KERNEL32" in pattern
			var is_real_harmony = "harmony" in file_name.to_lower() and "Harmony" in content_cleaned
			
			if is_memory_op and is_real_harmony:
				continue # 豁免：这是补丁库的分内之事
			
			current_score += weight
			
			# 颜色逻辑: 高分红，低分橙
			var line_color = "orange"
			if weight >= 80: line_color = "red"
			
			report_lines.append("[color=%s]%s[/color]" % [line_color, desc])

	return {
		"score": current_score,
		"details": report_lines
	}
# 这是一个每秒能处理几百MB的 C++ 封装调用
# === ⚡ 异步清洗引擎 (Anti-Freeze & Anti-Truncation) ===
# 这个函数现在是异步的，必须用 await 调用
func extract_readable_text_async(bytes: PackedByteArray) -> String:
	var size = bytes.size()
	var chunk_size = 100000 # 每处理 10万 字节歇一次 (平衡速度与流畅度)
	
	# 我们直接在原始数组上修改，比字符串拼接快得多
	# 将所有不可见字符(包括导致截断的 null)替换为空格(32)
	for i in range(size):
		var b = bytes[i]
		# 如果是控制字符(0-31) 或 扩展ASCII(>126)，替换为空格
		# 注意：保留换行符(10)和回车(13)可能有助于格式分析，但为了保险统统变空格也可以
		if b < 32 or b > 126:
			bytes[i] = 32 # Space
		
		# 防卡死机制：每处理一定数量，挂起一帧
		if i % chunk_size == 0 and i > 0:
			await get_tree().process_frame
			
	# 现在数组里没有 00 了，可以安全转换，不会被截断！
	return bytes.get_string_from_ascii()
	
func get_all_files(path: String, extensions: Array) -> Array:
	var files = []
	var dir = DirAccess.open(path)
	if dir:
		dir.list_dir_begin()
		var file_name = dir.get_next()
		while file_name != "":
			if dir.current_is_dir():
				if file_name != "." and file_name != "..":
					files.append_array(get_all_files(path + "/" + file_name, extensions))
			else:
				if file_name.get_extension().to_lower() in extensions:
					files.append(path + "/" + file_name)
			file_name = dir.get_next()
	return files
