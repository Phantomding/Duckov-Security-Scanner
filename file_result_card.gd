# FileResultCard.gd
extends PanelContainer

@onready var status_icon = $VBoxContainer/HeaderBox/StatusIcon
@onready var summary_label = $VBoxContainer/HeaderBox/SummaryLabel
@onready var toggle_btn = $VBoxContainer/HeaderBox/ToggleButton
@onready var details_box = $VBoxContainer/DetailsBox

# 定义风险等级常量 (和 scanner.gd 保持一致)
enum RiskLevel { INFO, WARNING, DANGER, CRITICAL }

func _ready():
	# 连接按钮信号
	toggle_btn.toggled.connect(_on_toggle)
	details_box.visible = false # 默认折叠
	details_box.fit_content = true # 让高度自适应内容

func _on_toggle(pressed):
	details_box.visible = pressed
	toggle_btn.text = "收起详情 ▲" if pressed else "展开详情 ▼"

# === 核心：设置数据 (包含动态颜色逻辑) ===
func setup(report: Dictionary):
	# 1. 计算最高风险等级
	var max_risk = RiskLevel.INFO
	for cat in report["permissions"]:
		for item in report["permissions"][cat]:
			if item["level"] > max_risk: max_risk = item["level"]
	
	if report["is_obfuscated"]: max_risk = RiskLevel.CRITICAL

	# === 🎨 核心修改：动态背景色 ===
	# 获取当前的 StyleBox 并复制一份 (必须复制，否则所有卡片颜色会一起变)
	# 确保你的根节点 PanelContainer 在主题里有一个 "panel" 样式的 StyleBoxFlat
	var style_box = get_theme_stylebox("panel").duplicate()
	
	# 定义颜色变量 (默认值)
	var bg_color = Color("#252525") 
	var border_color = Color("#444444") 
	var status_text = ""
	var icon = ""
	var title_color = "#ffffff"

	# 根据风险设置颜色 (使用极深的背景色 + 亮色边框，看起来更有质感)
	if max_risk == RiskLevel.INFO:
		icon = "🔵"
		title_color = "#88ccff" # 亮蓝
		status_text = "功能型 Mod (安全)"
		bg_color = Color("#112233") # 深蓝背景 (极暗)
		border_color = Color("#335577") # 亮蓝边框
		
	elif max_risk == RiskLevel.WARNING:
		icon = "⚠️"
		title_color = "orange"
		status_text = "需注意"
		bg_color = Color("#332200") # 深橙/棕色背景
		border_color = Color("#775533") # 亮橙边框
		
	elif max_risk >= RiskLevel.DANGER:
		icon = "🚫"
		title_color = "#ff4444" # 亮红
		status_text = "高风险"
		bg_color = Color("#331111") # 深红背景
		border_color = Color("#773333") # 亮红边框
		
	else: # 纯净 (RiskLevel.INFO 以下，或者没有权限)
		icon = "✅"
		title_color = "#44ff44" # 亮绿
		status_text = "纯净 Mod"
		bg_color = Color("#113322") # 深绿背景
		border_color = Color("#337755") # 亮绿边框

	# 应用颜色样式
	style_box.bg_color = bg_color
	style_box.border_width_left = 4 # 左边框加粗，作为状态指示条
	style_box.border_width_top = 1
	style_box.border_width_right = 1
	style_box.border_width_bottom = 1
	style_box.border_color = border_color
	style_box.corner_radius_top_left = 8
	style_box.corner_radius_top_right = 8
	style_box.corner_radius_bottom_right = 8
	style_box.corner_radius_bottom_left = 8
	
	# 重新赋值给当前节点
	add_theme_stylebox_override("panel", style_box)

	# 2. 设置顶部文字 (使用了上面定义的颜色)
	status_icon.text = icon
	summary_label.text = "%s  |  [color=%s]%s[/color]" % [report["filename"], title_color, status_text]
	
	# 如果有意图分析结果，追加显示在概览里
	if report["intents"].size() > 0:
		summary_label.text += " [color=#cccccc](%s)[/color]" % report["intents"][0]

	# 3. 生成详情文本 (硬核模式)
	var text = "\n[color=#666666]--- 详细审计报告 ---[/color]\n"
	
	# 混淆警告
	if report["is_obfuscated"]:
		text += "[color=red]🎲 [高危] 代码混乱度极高 (Entropy: %.2f)[/color]\n" % report["entropy"]
		text += "[color=orange]   └─ 警告: 代码被加密或加壳，无法审计内部逻辑。[/color]\n"
	else:
		text += "[color=#44ff44]🛡️ 代码结构清晰 (Entropy: %.2f)[/color]\n" % report["entropy"]
	
	# 权限列表渲染
	var has_content = false
	for cat in report["permissions"]:
		var items = report["permissions"][cat]
		if items.size() > 0:
			has_content = true
			text += "\n[b]%s 权限:[/b]\n" % cat
			for item in items:
				var prefix = "   • "
				var item_color = "#cccccc"
				
				if item["level"] >= RiskLevel.DANGER: 
					item_color = "#ff6666"
					prefix = "   🚫 "
				elif item["level"] == RiskLevel.WARNING:
					item_color = "orange"
					prefix = "   ⚠️ "
				elif item["level"] == RiskLevel.INFO:
					item_color = "#88ccff"
					prefix = "   🔹 "
				
				text += "[color=%s]%s%s [color=#666666](%s)[/color][/color]\n" % [item_color, prefix, item["desc"], item["keyword"]]
	
	if not has_content and not report["is_obfuscated"]:
		text += "\n[i]未检测到任何敏感权限调用。[/i]"
		
	details_box.text = text
