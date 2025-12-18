@tool
extends Panel

# 可以在检查器里调整颜色和虚线参数
@export var border_color: Color = Color.WHITE
@export var border_width: float = 4.0
@export var dash_length: float = 10.0 # 实线长度
@export var gap_length: float = 10.0  # 间隔长度

func _draw():
	# 获取 Panel 的大小
	var rect = Rect2(Vector2.ZERO, size)
	
	# 为了防止边框画在外面被裁剪，稍微向内缩一点
	var offset = border_width / 2.0
	var p1 = Vector2(offset, offset)
	var p2 = Vector2(size.x - offset, offset)
	var p3 = Vector2(size.x - offset, size.y - offset)
	var p4 = Vector2(offset, size.y - offset)
	
	# 顺时针画四条边 (Godot 4 提供了 draw_dashed_line)
	# 上边
	draw_dashed_line(p1, p2, border_color, border_width, dash_length, true)
	# 右边
	draw_dashed_line(p2, p3, border_color, border_width, dash_length, true)
	# 下边
	draw_dashed_line(p3, p4, border_color, border_width, dash_length, true)
	# 左边
	draw_dashed_line(p4, p1, border_color, border_width, dash_length, true)

# 当 Panel 大小改变时，强制重绘
func _notification(what):
	if what == NOTIFICATION_RESIZED:
		queue_redraw()
