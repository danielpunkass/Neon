import Foundation
import SwiftTreeSitter

public struct TreeSitterParseLayer {

	// A parse layer represents a parser for a specific language, and all the
	// native TreeSitter trees that resulted from parsing at that layer with that language.
	let language: Language
	let parser: Parser
	var trees: [Tree]

	#warning("temporary workaround")
	var tree: Tree? { return trees.first }

	// Sublayers are created for each of the separate injected languages that are discovered
	// during parsing and which
	var subLayers: [TreeSitterParseLayer]

	init(language: Language) throws {
		self.language = language
        self.parser = Parser()
		try self.parser.setLanguage(language)
		self.trees = []
		self.subLayers = []
    }

	func tree(in range: Range<UInt32>) -> Tree? {
		#warning("TODO: Find the right tree for the given range")
		return self.trees.first
	}

    func node(in range: Range<UInt32>) -> Node? {
		guard let tree = tree(in: range), let root = tree.rootNode else {
            return nil
        }

        return root.descendant(in: range)
    }

	#warning("Should return updated state?")
    func applyEdit(_ edit: InputEdit) {
#warning("TODO: How to deal with applied edits in a multi-tree scenario?")
		for tree in self.trees {
			tree.edit(edit)
		}
    }

    func changedByteRanges(for otherState: TreeSitterParseLayer) -> [Range<UInt32>] {
        let otherTree = otherState.tree

        switch (tree, otherTree) {
        case (let t1?, let t2?):
            return t1.changedRanges(from: t2).map({ $0.bytes })
        case (nil, let t2?):
            let range = t2.rootNode?.byteRange

            return range.flatMap({ [$0] }) ?? []
        case (_, nil):
            return []
        }
    }

    func copy() -> TreeSitterParseLayer {
		var copyLayer = try! TreeSitterParseLayer(language: self.language)
		copyLayer.trees = self.trees.compactMap { $0.copy() }
		copyLayer.subLayers = self.subLayers.map { $0.copy() }
		return copyLayer
    }
}

extension Parser {
    func parse(state: TreeSitterParseLayer, string: String, limit: Int? = nil) -> TreeSitterParseLayer {
		#warning("should parse each tree in turn")
		var newTrees: [Tree] = []
		for tree in state.trees {
			if let updatedTree = parse(tree: tree, string: string, limit: limit) {
				newTrees.append(updatedTree)
			}
		}

		var newState = state.copy()
		newState.trees = newTrees
		return newState
    }

    func parse(state: TreeSitterParseLayer, readHandler: @escaping Parser.ReadBlock) -> TreeSitterParseLayer {
		var newTrees: [Tree] = []
		#warning("Need to do something here to indicate whether to reparse regions based on existing trees or else start from scratch?")
		if state.trees.count == 0 {
			if let updatedTree = parse(tree: nil, readBlock: readHandler) {
				newTrees.append(updatedTree)
			}
		}

		for tree in state.trees {
			if let updatedTree = parse(tree: tree, readBlock: readHandler) {
				newTrees.append(updatedTree)
			}
		}
		var newState = state.copy()
		newState.trees = newTrees
		return newState
    }
}
