// Exercise the real Web form's toolbar callbacks against the shared iOS fixtures.
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const assert = require("node:assert/strict");
const ts = require("typescript");
const root = path.resolve(__dirname, "../..");
const source = fs.readFileSync(
    path.join(root, "src/frontend/src/form.tsx"),
    "utf8",
);
const ast = ts.createSourceFile(
    "form.tsx",
    source,
    ts.ScriptTarget.Latest,
    true,
    ts.ScriptKind.TSX,
);
const callbacks = [];
let imageCallback;
function visit(node) {
    if (
        ts.isCallExpression(node) &&
        node.expression.getText(ast) === "formButton"
    ) {
        callbacks.push(node.arguments[1].getText(ast));
    }
    if (
        ts.isVariableDeclaration(node) &&
        node.name.getText(ast) === "insertNewPicture"
    ) {
        imageCallback = node.initializer.getText(ast);
    }
    ts.forEachChild(node, visit);
}
visit(ast);
assert.equal(
    callbacks.length,
    10,
    "Review Web toolbar mapping when buttons change",
);
function evaluate(expression, url) {
    const js = ts.transpile(`const transform = ${expression}; transform;`);
    return vm.runInNewContext(js, { promptPopUp: async () => url });
}
(async () => {
    const fixtures = JSON.parse(
        fs.readFileSync(
            path.join(
                root,
                "ios/TAGGR/TAGGRTests/Fixtures/composer-web-parity.json",
            ),
            "utf8",
        ),
    );
    const index = { bold: 0, italic: 1, list: 3, quote: 5, link: 6 };
    for (const item of fixtures.markdown) {
        const transform = evaluate(callbacks[index[item.action]], item.url);
        const replacement = await transform(
            item.text.slice(item.start, item.start + item.length),
        );
        assert.equal(
            item.text.slice(0, item.start) +
                replacement +
                item.text.slice(item.start + item.length),
            item.expected,
            JSON.stringify(item),
        );
    }
    for (const item of fixtures.images) {
        const result = evaluate(imageCallback)(
            item.text,
            item.start,
            item.markers,
        );
        assert.equal(result.newValue, item.expected);
        assert.equal(
            result.newCursor,
            item.expected.length - (item.text.length - item.start),
        );
    }
    console.log(
        `Web composer parity: ${fixtures.markdown.length} Markdown + ${fixtures.images.length} image cases passed`,
    );
})().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
