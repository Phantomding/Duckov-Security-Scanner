extends Control

# ==========================================
# 🦆 Duckov Mod Inspector v1.6 (UI Card Update)
# ==========================================

const MAX_FILE_SIZE = 20 * 1024 * 1024 # 20MB 限制
var is_scanning = false # 🔒 扫描锁

# 📌 引用卡片预制体 (请确保路径正确)
var card_scene = preload("res://FileResultCard.tscn")

# 📌 节点引用
@onready var status_label = $StatusLabel
# 注意：这里现在引用的是 VBoxContainer，不是原来的 RichTextLabel
@onready var result_list = $ResultScroll/ResultList 

# === 1. 核心定义: 风险等级 ===
enum RiskLevel { INFO, WARNING, DANGER, CRITICAL }

# === 2. 通用权限规则库 (Permission Rules) ===
var permission_rules = {
	# 🌐 网络通信
	"Network": {
		"System\\.Net": [RiskLevel.INFO, "基础网络库引用"],
		"HttpClient": [RiskLevel.WARNING, "具备 HTTP 联网请求能力"],
		"UnityWebRequest": [RiskLevel.WARNING, "Unity 引擎联网接口"],
		"Socket": [RiskLevel.WARNING, "Socket 长连接 (聊天/P2P)"],
		"WebClient": [RiskLevel.WARNING, "老式网络客户端"],
		"UploadData": [RiskLevel.DANGER, "上传数据接口"],
		"UploadString": [RiskLevel.DANGER, "上传文本接口"],
		"discord\\.com": [RiskLevel.DANGER, "硬编码 Discord 链接 (疑似 Webhook)"],
		"iplogger": [RiskLevel.CRITICAL, "包含 IP 追踪链接"]
	},

	# 📂 文件系统
	"FileSystem": {
		"System\\.IO": [RiskLevel.INFO, "基础文件操作库"],
		"File\\.Delete": [RiskLevel.DANGER, "具备删除文件能力"],
		"Directory\\.Delete": [RiskLevel.DANGER, "具备删除文件夹能力"],
		"GetFiles": [RiskLevel.WARNING, "遍历文件列表"],
		"PlayerPrefs": [RiskLevel.INFO, "读写游戏注册表/配置"],
		"Environment\\.GetFolderPath": [RiskLevel.WARNING, "获取系统敏感路径 (如文档/桌面)"]
	},

	# ⚙️ 系统/进程
	"System": {
		"Process\\.Start": [RiskLevel.DANGER, "启动外部进程 (CMD/EXE)"],
		"Environment\\.Exit": [RiskLevel.CRITICAL, "强制杀进程/退出游戏"],
		"RegistryKey": [RiskLevel.DANGER, "操作 Windows 注册表"],
		"Quit": [RiskLevel.WARNING, "调用退出逻辑 (Application.Quit)"]
	},

	# 🎭 动态执行/隐藏
	"Reflection": {
		"System\\.Reflection": [RiskLevel.INFO, "引用反射库 (动态执行)"],
		"MethodBase\\.Invoke": [RiskLevel.WARNING, "动态调用未知函数"],
		"Activator\\.CreateInstance": [RiskLevel.WARNING, "动态创建对象"],
		"Assembly\\.Load": [RiskLevel.DANGER, "内存加载二进制代码 (Payload)"],
		"Type\\.GetType": [RiskLevel.WARNING, "动态获取类型 (可能用于隐藏目标)"]
	},

	# 🆔 敏感信息
	"Privacy": {
		"SteamId": [RiskLevel.WARNING, "读取 SteamID"],
		"CSteamID": [RiskLevel.WARNING, "Steam 身份结构"],
		"session": [RiskLevel.WARNING, "包含 'session' 关键词"],
		"wallet": [RiskLevel.DANGER, "包含钱包/支付关键词"]
	}
}

# === 3. 意图推理规则库 (Context Engine) ===
var intent_rules = {
	"Discord_Steal": {
		"cat_req": "Network",
		"evidence": ["discord.com/api/webhooks", "discordapp.com/api/webhooks"],
		"desc": "🔴 [意图分析] 疑似数据外传: 发现 Discord Webhook 链接"
	},
	"Local_Server": {
		"cat_req": "Network",
		"evidence": ["127.0.0.1", "localhost", "0.0.0.0"],
		"desc": "🟢 [意图分析] 本地联机: 发现本地服务器回环地址"
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
	}
}

# 缓存正则
var compiled_rules = {}

func _ready():
	DisplayServer.window_set_title("DMI v1.5 - Universal Audit")
	
	# 预编译正则
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
	
	# === 1. 清空旧卡片 ===
	for child in result_list.get_children():
		child.queue_free()
	
	var all_files = []
	status_label.text = "正在解析文件列表..."
	await get_tree().process_frame
	
	# 收集文件
	for path in files:
		if DirAccess.dir_exists_absolute(path):
			all_files.append_array(get_all_files(path, ["dll"]))
		elif path.get_extension().to_lower() == "dll":
			all_files.append(path)
			
	if all_files.size() == 0:
		status_label.text = "❌ 未找到 .dll 文件 (仅支持 C# Mod)"
		is_scanning = false
		return
		
	# 开始扫描
	var total_scanned = 0
	
	for file_path in all_files:
		total_scanned += 1
		status_label.text = "正在审计: %d / %d" % [total_scanned, all_files.size()]
		
		# 每5个文件暂停一帧，防止UI卡顿
		if total_scanned % 5 == 0: await get_tree().process_frame
		
		# === 2. 核心扫描 (获取数据) ===
		var report = await scan_single_file(file_path)
		
		# === 3. 生成 UI 卡片 (Card) ===
		var card = card_scene.instantiate()
		result_list.add_child(card)
		card.setup(report) # 将数据注入卡片
			
	status_label.text = "审计完成 (共 %d 个文件)" % total_scanned
	is_scanning = false

# === 核心扫描引擎 (返回结构化数据) ===
func scan_single_file(path: String) -> Dictionary:
	var file_obj = FileAccess.open(path, FileAccess.READ)
	# 如果打开失败，返回空报告
	if not file_obj: 
		return {"filename": path.get_file(), "permissions": {}, "intents": [], "entropy": 0, "is_obfuscated": false}
	
	var file_len = file_obj.get_length()
	if file_len > MAX_FILE_SIZE:
		return {"filename": path.get_file() + " (过大)", "permissions": {}, "intents": ["⚠️ 文件过大跳过扫描"], "entropy": 0, "is_obfuscated": false}

	# 1. 异步清洗与分析
	var content_bytes = file_obj.get_buffer(file_len)
	var analysis = await extract_readable_text_async(content_bytes)
	var content = analysis["text"]
	var entropy = analysis["entropy"]
	
	# 2. 初始化报告对象
	var report = {
		"filename": path.get_file(),
		"entropy": entropy,
		"is_obfuscated": false,
		"permissions": {}, # 结构: {"Network": [items], ...}
		"intents": []
	}
	
	# 3. 混淆判定 (Entropy Check)
	if entropy > 7.2: report["is_obfuscated"] = true
	
	# 4. 权限扫描 (Permission Scan)
	for category in compiled_rules:
		report["permissions"][category] = []
		var rules = compiled_rules[category]
		
		for pattern in rules:
			var regex = rules[pattern]
			if regex.search(content):
				var raw_rule = permission_rules[category][pattern]
				report["permissions"][category].append({
					"keyword": pattern,
					"level": raw_rule[0],
					"desc": raw_rule[1]
				})

	# 5. 意图推理 (Intent Engine)
	for intent_name in intent_rules:
		var rule = intent_rules[intent_name]
		var required_cat = rule["cat_req"]
		
		if report["permissions"].has(required_cat) and report["permissions"][required_cat].size() > 0:
			for ev in rule["evidence"]:
				if ev in content:
					report["intents"].append(rule["desc"])
					break 

	return report

# === ⚡ 异步清洗引擎 (含香农熵计算) ===
func extract_readable_text_async(bytes: PackedByteArray) -> Dictionary:
	var size = bytes.size()
	var chunk_size = 100000 
	var byte_counts = PackedInt64Array()
	byte_counts.resize(256)
	byte_counts.fill(0)
	
	for i in range(size):
		var b = bytes[i]
		byte_counts[b] += 1 # 统计熵
		
		if (b < 32 and b != 10 and b != 13) or b > 126:
			bytes[i] = 32 # 清洗为 Space
		
		if i % chunk_size == 0 and i > 0:
			await get_tree().process_frame
			
	# 计算熵
	var entropy = 0.0
	var total_float = float(size)
	if total_float > 0:
		for count in byte_counts:
			if count > 0:
				var p = float(count) / total_float
				entropy -= p * (log(p) / log(2))
				
	return {"text": bytes.get_string_from_ascii(), "entropy": entropy}

# === 辅助工具 ===
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
