class_name CursorModelCatalog
extends RefCounted

const SOURCE_DIRECTORY := "res://assets/raw_original_content/UI0001/CURSORS"
const OUTPUT_DIRECTORY := "res://assets/converted/ui/cursor_models"
const MODEL_SCALE := 0.0625

# Semantic runtime names deliberately stay independent from XBF casing.  Each
# CursorType gets its own output scene even when it temporarily reuses another
# original XBF. This makes a future replacement a one-line catalog change.
const MODEL_FILES := {
	&"pointer": "CU_Pointer_H0.xbf",
	&"move": "CU_Move_H0.xbf",
	&"attack": "CU_attack_H0.xbf",
	&"cant_move": "CU_Cant_Move_H0.xbf",
	&"enter": "CU_Enter_H0.xbf",
	&"select": "CU_Select_H0.xbf",
	&"infantry_rock": "CU_Enter_H0.xbf",
	&"cant_sell": "CU_Cant_Sell_H0.xbf",
	&"cant_repair": "CU_Cant_Repair_H0.xbf",
	&"target_ability": "CU_Move_Map_H0.xbf",
	&"dn3": "CU_Move_Map_H0.xbf",
	&"sell": "CU_Sell_H0.xbf",
	&"repair": "CU_Repair_H0.xbf",
	&"deploy": "CU_Deploy_H0.xbf",
	&"cant_enter": "CU_Cant_Enter_H0.xbf",
	# Cursor XBF names use the source renderer's inverted screen-Y convention.
	# Horizontal directions survive conversion, while every vertical component
	# must be reversed for Godot screen coordinates.
	&"scroll_n": "CU_Scroll_down_H0.xbf",
	&"scroll_ne": "CU_Scroll_downright_H0.xbf",
	&"scroll_e": "CU_Scroll_right_H0.xbf",
	&"scroll_se": "CU_Scroll_upright_H0.xbf",
	&"scroll_s": "CU_Scroll_up_H0.xbf",
	&"scroll_sw": "CU_Scroll_upleft_H0.xbf",
	&"scroll_w": "CU_Scroll_left_H0.xbf",
	&"scroll_nw": "CU_Scroll_downleft_H0.xbf",
	# Cant Scroll models additionally reverse their horizontal component, so
	# both axes in their XBF names must be reversed for the runtime direction.
	&"cant_scroll_n": "CU_Cant_Scroll_Down_H0.xbf",
	&"cant_scroll_ne": "CU_Cant_Scroll_Downleft_H0.xbf",
	&"cant_scroll_e": "CU_Cant_Scroll_left_H0.xbf",
	&"cant_scroll_se": "CU_Cant_Scroll_Upleft_H0.xbf",
	&"cant_scroll_s": "CU_Cant_Scroll_Up_H0.xbf",
	&"cant_scroll_sw": "CU_Cant_Scroll_Upright_H0.xbf",
	&"cant_scroll_w": "CU_Cant_Scroll_right_H0.xbf",
	&"cant_scroll_nw": "CU_Cant_Scroll_Downright_H0.xbf",
	&"dn4": "CU_DeathHand_H0.xbf",
	&"dn5": "CU_PickUp_H0.xbf",
	&"dn6": "CU_Teleport_H0.xbf",
	&"gather": "CU_Move_H0.xbf",
	&"cant_deploy": "CU_Cant_Deploy_H0.xbf",
}


static func source_path(model_key: StringName) -> String:
	var file_name := String(MODEL_FILES.get(model_key, ""))
	return SOURCE_DIRECTORY.path_join(file_name) if not file_name.is_empty() else ""


static func output_path(model_key: StringName) -> String:
	return OUTPUT_DIRECTORY.path_join("%s.scn" % model_key) if MODEL_FILES.has(model_key) else ""
