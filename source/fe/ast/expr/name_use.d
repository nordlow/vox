/// Copyright: Copyright (c) 2017-2019 Andrey Penechko.
/// License: $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).
/// Authors: Andrey Penechko.
module fe.ast.expr.name_use;

import all;

enum NameUseFlags : ushort
{
	isSymResolved = AstFlags.userFlag << 0,
	// used to prevent parentheses-free call when:
	// - function address is taken
	// - alias is taken
	forbidParenthesesFreeCall = AstFlags.userFlag << 1,
}

@(AstType.expr_name_use)
struct NameUseExprNode {
	mixin ExpressionNodeData!(AstType.expr_name_use);
	AstIndex parentScope;
	union
	{
		private AstIndex _entity; // used when resolved, node contains Identifier internally
		private Identifier _id; // used when not yet resolved
	}

	bool isSymResolved() { return cast(bool)(flags & NameUseFlags.isSymResolved); }
	bool forbidParenthesesFreeCall() { return cast(bool)(flags & NameUseFlags.forbidParenthesesFreeCall); }

	this(TokenIndex loc, AstIndex parentScope, Identifier id, AstIndex type = AstIndex.init)
	{
		this.loc = loc;
		this.astType = AstType.expr_name_use;
		this.flags = AstFlags.isExpression;
		this.state = AstNodeState.name_register_nested_done;
		this.parentScope = parentScope;
		this._id = id;
		this.type = type;
	}

	void resolve(AstIndex n, CompilationContext* c) {
		_entity = n;
		assert(_entity);
		this.flags |= NameUseFlags.isSymResolved;
	}
	AstIndex entity() { return isSymResolved ? _entity : AstIndex(); }
	ref Identifier id(CompilationContext* context) return {
		return isSymResolved ? _entity.get_node_id(context) : _id;
	}

	T* tryGet(T, AstType _astType)(CompilationContext* context) {
		assert(isSymResolved);
		AstNode* entityNode = context.getAstNode(_entity);
		if (entityNode.astType != _astType) return null;
		return cast(T*)entityNode;
	}

	T* get(T, AstType _astType)(CompilationContext* context) {
		assert(isSymResolved);
		AstNode* entityNode = context.getAstNode(_entity);
		assert(entityNode.astType == _astType, format("%s used on %s", _astType, entityNode.astType));
		return cast(T*)entityNode;
	}

	alias varDecl = get!(VariableDeclNode, AstType.decl_var);
	alias funcDecl = get!(FunctionDeclNode, AstType.decl_function);
	alias structDecl = get!(StructDeclNode, AstType.decl_struct);
	alias enumDecl = get!(EnumDeclaration, AstType.decl_enum);
	alias enumMember = get!(EnumMemberDecl, AstType.decl_enum_member);

	alias tryVarDecl = tryGet!(VariableDeclNode, AstType.decl_var);
	alias tryFuncDecl = tryGet!(FunctionDeclNode, AstType.decl_function);
	alias tryStructDecl = tryGet!(StructDeclNode, AstType.decl_struct);
	alias tryEnumDecl = tryGet!(EnumDeclaration, AstType.decl_enum);
	alias tryEnumMember = tryGet!(EnumMemberDecl, AstType.decl_enum_member);
}

void print_name_use(NameUseExprNode* node, ref AstPrintState state)
{
	state.print("NAME_USE ", node.type.printer(state.context), " ", state.context.idString(node.id(state.context)));
}

void post_clone_name_use(NameUseExprNode* node, ref CloneState state)
{
	CompilationContext* c = state.context;
	state.fixScope(node.parentScope);
	if (node.isSymResolved)
		state.fixAstIndex(node._entity);
	// _entity is resolved in template args
}

void name_resolve_name_use(ref AstIndex nodeIndex, NameUseExprNode* node, ref NameResolveState state) {
	CompilationContext* c = state.context;
	node.state = AstNodeState.name_resolve;
	scope(exit) node.state = AstNodeState.name_resolve_done;

	Identifier id = node.id(c);

	Scope* currentScope = node.parentScope.get_scope(c);

	AstIndex entity = lookupScopeIdRecursive(currentScope, id, node.loc, c);

	if (entity == CommonAstNodes.node_error)
	{
		c.error(node.loc, "undefined identifier `%s`", c.idString(id));
		node.flags |= AstFlags.isError;
		node.resolve(CommonAstNodes.node_error, c);
		return;
	}

	node.resolve(entity, c);
	AstNode* entityNode = entity.get_node(c);

	switch(entityNode.astType) with(AstType) {
		case decl_var:
			auto var = entityNode.as!VariableDeclNode(c);
			if (var.isMember) lowerToMember(nodeIndex, node, var.scopeIndex, MemberSubType.struct_member, state);
			break;
		case decl_function:
			auto func = entityNode.as!FunctionDeclNode(c);
			if (func.isMember) lowerToMember(nodeIndex, node, 0, MemberSubType.struct_method, state);
			break;
		case decl_enum_member, error:
			// valid expr
			break;
		case decl_struct, decl_enum:
			node.flags |= AstFlags.isType;
			break;
		case decl_alias:
			require_name_resolve(entity, state);
			if (entityNode.isType) node.flags |= AstFlags.isType;
			// replace current node with aliased entity
			// this will only replace node index of the current owner, other references will remain
			// happens for enum type for example: it is referenced from enum type and from enum members
			nodeIndex = entity.get!AliasDeclNode(c).initializer;
			break;
		case type_ptr:
		case type_static_array:
		case type_slice:
		case expr_name_use:
		case type_basic:
		case literal_array:
		case decl_alias_array:
			// Happens after template arg replacement. Similar to alias
			nodeIndex = entity;
			break;
		case decl_template:
			node.flags |= AstFlags.isTemplate;
			break;
		default:
			c.internal_error("Unknown entity %s", entityNode.astType);
	}
}

private void lowerToMember(ref AstIndex nodeIndex, NameUseExprNode* node, uint scopeIndex, MemberSubType subType, ref NameResolveState state)
{
	CompilationContext* c = state.context;
	// rewrite as this.entity
	// let member_access handle everything else
	AstIndex thisName = c.appendAst!NameUseExprNode(node.loc, node.parentScope, CommonIds.id_this);
	require_name_resolve(thisName, state);
	AstIndex member = c.appendAst!MemberExprNode(node.loc, node.parentScope, thisName, nodeIndex, scopeIndex, subType);
	if (node.isLvalue)
		member.flags(c) |= AstFlags.isLvalue;
	nodeIndex = member;
	auto memberNode = member.get!MemberExprNode(c);
	memberNode.state = AstNodeState.name_resolve_done;
}

// Get type from variable declaration
void type_check_name_use(ref AstIndex nodeIndex, NameUseExprNode* node, ref TypeCheckState state)
{
	CompilationContext* c = state.context;

	if (state.parentType.isDefined &&
		state.parentType.get_effective_node(c) == CommonAstNodes.type_alias) {
		node.flags |= NameUseFlags.forbidParenthesesFreeCall;
	}

	c.assertf(node.entity.isDefined, node.loc, "name null %s %s", node.isSymResolved, node.state);
	switch(node.entity.astType(c))
	{
		case AstType.decl_template:
			node.state = AstNodeState.type_check_done;
			break;

		case AstType.decl_function:
			// check forbidParenthesesFreeCall to prevent call on func address take
			if (!node.forbidParenthesesFreeCall)
			{
				// Call without parenthesis
				// rewrite as call
				nodeIndex = c.appendAst!CallExprNode(node.loc, AstIndex(), nodeIndex);
				nodeIndex.setState(c, AstNodeState.name_resolve_done);
				require_type_check(nodeIndex, state);
				break;
			}
			goto default;

		case AstType.decl_enum_member:
			require_type_check(node._entity, state);
			goto default;

		default:
			node.state = AstNodeState.type_check;
			c.assertf(node.isSymResolved, node.loc, "not resolved");
			node.type = node.entity.get_node_type(state.context);
			assert(node.type.isDefined);
			node.state = AstNodeState.type_check_done;
			break;
	}
}

ExprValue ir_gen_name_use(ref IrGenState gen, IrIndex currentBlock, ref IrLabel nextStmt, NameUseExprNode* node)
{
	CompilationContext* c = gen.context;
	AstNode* entity = node.entity.get_node(c);

	c.assertf(entity !is null, node.loc, "name null %s %s", node.isSymResolved, node.state);

	switch (entity.astType) with(AstType)
	{
		case decl_enum_member:
		{
			gen.builder.addJumpToLabel(currentBlock, nextStmt);
			return ExprValue(node.entity.get!EnumMemberDecl(c).getInitVal(c));
		}
		case decl_var:
		{
			ExprValue result = node.varDecl(c).irValue;
			gen.builder.addJumpToLabel(currentBlock, nextStmt);
			return result;
		}
		case decl_function:
			gen.builder.addJumpToLabel(currentBlock, nextStmt);
			return ExprValue(entity.as!FunctionDeclNode(c).getIrIndex(c));
		default:
			c.internal_error(node.loc, "ir_gen_name_use %s", entity.astType);
			assert(false);
	}
}
