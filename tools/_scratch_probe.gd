extends SceneTree

func _initialize() -> void:
	var v: Variant = Vector3(1, 2, 3)
	var o := v as Object
	print("vector as Object -> ", o, " null? ", o == null)
	var n: Variant = Node.new()
	var o2 := n as Object
	print("node as Object -> ", o2 != null)
	quit(0)
