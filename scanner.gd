extends Control

# ==========================================
# 🛡️ D.M.I. v1.7 - Targeted Reinforcement
# ==========================================

const MAX_FILE_SIZE = 20 * 1024 * 1024 
var is_scanning = false 

var card_scene = preload("res://FileResultCard.tscn")

@onready var status_label = $StatusLabel
@onready var result_list = $ResultScroll/ResultList 

enum RiskLevel { INFO, WARNING, DANGER, CRITICAL }

# === 权限规则库 (v1.7 升级版) ===
var permission_rules = {
	"Network": {
		"System\\.Net": [RiskLevel.INFO, "基础网络库引用"], 
		"HttpClient": [RiskLevel.WARNING, "具备 HTTP 联网请求能力"],
		"UnityWebRequest": [RiskLevel.WARNING, "Unity 引擎联网接口"],
		"WebClient": [RiskLevel.WARNING, "老式网络客户端"],
		"System\\.Net\\.Sockets": [RiskLevel.WARNING, "引用底层 Socket 库"],
		"TcpListener": [RiskLevel.INFO, "建立本地服务器 (监听端口)"],
		"TcpClient": [RiskLevel.WARNING, "建立 TCP 连接 (主动连接)"],
		"UdpClient": [RiskLevel.WARNING, "建立 UDP 连接 (快速传输)"],
		"UploadData": [RiskLevel.DANGER, "上传数据接口"],
		"discord\\.com": [RiskLevel.DANGER, "硬编码 Discord 链接 (疑似 Webhook)"],
		"iplogger": [RiskLevel.CRITICAL, "包含 IP 追踪链接"]
	},
	"FileSystem": {
		"System\\.IO": [RiskLevel.INFO, "基础文件操作库"],
		"File\\.Write": [RiskLevel.INFO, "写入文件 (通常是配置文件)"], 
		"File\\.Copy": [RiskLevel.WARNING, "复制/克隆文件"], 
		"File\\.Move": [RiskLevel.WARNING, "移动/重命名文件"], 
		"File\\.Delete": [RiskLevel.DANGER, "具备删除文件能力"],
		"Directory\\.Delete": [RiskLevel.DANGER, "具备删除文件夹能力"],
		"GetFiles": [RiskLevel.WARNING, "遍历文件列表"],
		"Environment\\.GetFolderPath": [RiskLevel.WARNING, "获取系统敏感路径 (如文档/桌面)"],
		"Environment\\.SpecialFolder": [RiskLevel.WARNING, "枚举系统特殊路径"],
		
		# 👇 修正点：Temp 降级为 INFO，因为它太常见了 (如 Harmony 缓存)
		"Path\\.GetTempPath": [RiskLevel.INFO, "获取系统临时路径 (常见缓存操作)"],
		"\\.tmp": [RiskLevel.INFO, "读写临时文件"],
		
		# 👇 真正的威胁交给这些特征去抓：
		"System32": [RiskLevel.CRITICAL, "尝试访问 Windows 系统目录"],
		"AppData": [RiskLevel.WARNING, "尝试访问 AppData"],
		"\\.bat": [RiskLevel.DANGER, "涉及批处理脚本"],
		"\\.cmd": [RiskLevel.DANGER, "涉及脚本执行"],
		"\\.vbs": [RiskLevel.DANGER, "涉及 VBS 脚本"],
		"\\.exe": [RiskLevel.DANGER, "涉及可执行文件操作"] # v1.7.1 补充
	},
	"System": {
		"Process\\.Start": [RiskLevel.DANGER, "启动外部进程 (CMD/EXE)"],
		"Environment\\.Exit": [RiskLevel.CRITICAL, "强制杀进程/退出游戏"],
		"RegistryKey": [RiskLevel.DANGER, "操作 Windows 注册表"],
		"Quit": [RiskLevel.WARNING, "调用退出逻辑 (Application.Quit)"]
	},
	"Reflection": {
		"System\\.Reflection": [RiskLevel.INFO, "引用反射库 (动态执行)"],
		"MethodBase\\.Invoke": [RiskLevel.WARNING, "动态调用未知函数"],
		"Assembly\\.Load": [RiskLevel.DANGER, "内存加载二进制代码 (Payload)"],
		"Type\\.GetType": [RiskLevel.WARNING, "动态获取类型 (可能用于隐藏目标)"]
	},
	"Privacy": {
		# 👇 v1.7: 大幅增强对 SteamID 和隐私文件的检测
		"SteamId": [RiskLevel.WARNING, "读取 SteamID"],
		"CSteamID": [RiskLevel.WARNING, "Steam 身份结构"],
		"Steamworks": [RiskLevel.WARNING, "引用 Steamworks API (可能获取玩家身份)"], # v1.7
		"GetSteamID": [RiskLevel.WARNING, "尝试获取 Steam ID"], # v1.7
		"SteamUser": [RiskLevel.WARNING, "访问 Steam 用户数据"], # v1.7
		"user\\.cfg": [RiskLevel.WARNING, "尝试读取用户配置文件"], # v1.7 (塔科夫常见)
		"storage\\.json": [RiskLevel.WARNING, "尝试读取存档数据"], # v1.7
		"wallet": [RiskLevel.DANGER, "包含钱包/支付关键词"]
	}
}

# === 意图推理库 ===
var intent_rules = {
	"Local_Service": {
		"cat_req": "Network",
		"evidence": ["127.0.0.1", "localhost", "TcpListener", "HttpListener"],
		"desc": "🟢 [意图分析] 本地服务: 监听本地端口 (通常用于小地图/雷达)"
	},
	"Auto_Update": {
		"cat_req": "Network",
		"evidence": ["github.com", "releases/latest", "raw.githubusercontent"],
		"desc": "🔵 [意图分析] 自动更新: 发现 GitHub 仓库引用"
	},
	"Steam_P2P": {
		"cat_req": "Network",
		"evidence": ["SteamNetworking", "P2P"],
		"desc": "🟢 [意图分析] Steam 联机: 使用官方 P2P 接口"
	},
	"Discord_Steal": {
		"cat_req": "Network",
		"evidence": ["discord.com/api/webhooks", "discordapp.com/api/webhooks"],
		"desc": "🔴 [意图分析] 疑似数据外传: 发现 Discord Webhook 链接"
	},
	"Reverse_Shell": {
		"cat_req": "Network",
		"evidence": ["cmd.exe", "/bin/sh", "powershell", "/bin/bash"],
		"desc": "🚫 [高危意图] 远程控制: 发现 Socket 与命令行同时出现，疑似后门木马"
	}
}

var compiled_rules = {}

func _ready():
	DisplayServer.window_set_title("D.M.I. v1.7 - Universal Mod Audit")
	for category in permission_rules:
		compiled_rules[category] = {}
		for pattern in permission_rules[category]:
			var regex = RegEx.new()
			regex.compile(pattern)
			compiled_rules[category][pattern] = regex
	
	get_viewport().files_dropped.connect(_on_files_dropped)
	status_label.text = "将 Mod (.dll) 拖入此处查看权限仪表盘"

func _on_files_dropped(files):
	if is_scanning: return
	is_scanning = true
	
	for child in result_list.get_children():
		child.queue_free()
	
	var all_files = []
	status_label.text = "正在解析文件列表..."
	await get_tree().process_frame
	
	for path in files:
		if DirAccess.dir_exists_absolute(path):
			all_files.append_array(get_all_files(path, ["dll"]))
		elif path.get_extension().to_lower() == "dll":
			all_files.append(path)
			
	if all_files.size() == 0:
		status_label.text = "❌ 未找到 .dll 文件"
		is_scanning = false
		return
		
	var total_scanned = 0
	for file_path in all_files:
		total_scanned += 1
		status_label.text = "正在审计: %d / %d" % [total_scanned, all_files.size()]
		if total_scanned % 5 == 0: await get_tree().process_frame
		
		var report = await scan_single_file(file_path)
		var card = card_scene.instantiate()
		result_list.add_child(card)
		card.setup(report) 
			
	status_label.text = "审计完成 (共 %d 个文件)" % total_scanned
	is_scanning = false

func scan_single_file(path: String) -> Dictionary:
	var file_obj = FileAccess.open(path, FileAccess.READ)
	if not file_obj: return {"filename": path.get_file(), "permissions": {}, "entropy": 0}
	
	var file_len = file_obj.get_length()
	if file_len > MAX_FILE_SIZE:
		return {"filename": path.get_file() + " (过大)", "permissions": {}, "entropy": 0}

	var content_bytes = file_obj.get_buffer(file_len)
	var analysis = await extract_readable_text_async(content_bytes)
	var content = analysis["text"]
	var entropy = analysis["entropy"]
	
	# === 智能抗误报逻辑 (v1.6) ===
	var is_obfuscated = false
	var is_resource_heavy = false
	
	if entropy > 7.2:
		var csharp_signatures = ["<Module>", "mscorlib", "System.Private.CoreLib", "System.Void", "k__BackingField", "RuntimeCompatibilityAttribute"]
		var signature_hits = 0
		for sig in csharp_signatures:
			if sig in content: signature_hits += 1
		
		if signature_hits >= 2: is_resource_heavy = true # 资源包
		else: is_obfuscated = true # 恶意混淆

	var report = {
		"filename": path.get_file(),
		"entropy": entropy,
		"is_obfuscated": is_obfuscated,
		"is_resource_heavy": is_resource_heavy,
		"permissions": {} 
	}
	
	# === 权限扫描 ===
	for category in compiled_rules:
		report["permissions"][category] = []
		var rules = compiled_rules[category]
		for pattern in rules:
			var regex = rules[pattern]
			if regex.search(content):
				var raw_rule = permission_rules[category][pattern]
				var item = {
					"keyword": pattern,
					"level": raw_rule[0],
					"desc": raw_rule[1],
					"intent_note": "",
					"is_ghost": false
				}
				
				# 行内意图注入
				for intent_name in intent_rules:
					var rule = intent_rules[intent_name]
					if rule["cat_req"] == category:
						for ev in rule["evidence"]:
							if ev in content:
								item["intent_note"] = rule["desc"]
								if intent_name == "Local_Service" and item["level"] == RiskLevel.WARNING:
									item["level"] = RiskLevel.INFO
								if intent_name == "Reverse_Shell":
									item["level"] = RiskLevel.CRITICAL
								break 
				report["permissions"][category].append(item)

	# === 👻 幽灵引用检测 (v1.6) ===
	var ghost_check_rules = {
		"Network": {"ref_keyword": "System\\.Net", "activity_level_threshold": RiskLevel.WARNING},
		"FileSystem": {"ref_keyword": "System\\.IO", "activity_level_threshold": RiskLevel.WARNING},
		"Reflection": {"ref_keyword": "System\\.Reflection", "activity_level_threshold": RiskLevel.WARNING}
	}
	
	for category in report["permissions"]:
		var items = report["permissions"][category]
		if items.size() == 0: continue
		if not ghost_check_rules.has(category): continue
		
		var rule = ghost_check_rules[category]
		var ref_keyword = rule["ref_keyword"]
		var has_base_ref = false
		var base_ref_index = -1
		
		for i in range(items.size()):
			if items[i]["keyword"] == ref_keyword:
				has_base_ref = true
				base_ref_index = i
				break
		
		if has_base_ref:
			var has_activity = false
			for item in items:
				if item["keyword"] != ref_keyword:
					has_activity = true
					break
			if not has_activity:
				var ghost_item = items[base_ref_index]
				ghost_item["desc"] = "👻 [幽灵引用] 声明了库但未检测到使用 (懒惰作者)"
				ghost_item["level"] = -1 # 幽灵级别
				ghost_item["is_ghost"] = true

	return report

func extract_readable_text_async(bytes: PackedByteArray) -> Dictionary:
	var size = bytes.size()
	var chunk_size = 100000 
	var byte_counts = PackedInt64Array()
	byte_counts.resize(256)
	byte_counts.fill(0)
	
	for i in range(size):
		var b = bytes[i]
		byte_counts[b] += 1
		if (b < 32 and b != 10 and b != 13) or b > 126:
			bytes[i] = 32
		if i % chunk_size == 0 and i > 0:
			await get_tree().process_frame
			
	var entropy = 0.0
	var total_float = float(size)
	if total_float > 0:
		for count in byte_counts:
			if count > 0:
				var p = float(count) / total_float
				entropy -= p * (log(p) / log(2))
				
	return {"text": bytes.get_string_from_ascii(), "entropy": entropy}

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
