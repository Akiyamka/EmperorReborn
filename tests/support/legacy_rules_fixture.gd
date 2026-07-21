extends RefCounted

const LegacyRulesScript := preload("res://scripts/rules/rules.gd")


static func install(root: Node) -> Node:
	var existing := root.get_node_or_null("Rules")
	if existing != null:
		return existing
	var rules := LegacyRulesScript.new()
	rules.name = "Rules"
	root.add_child(rules)
	return rules
