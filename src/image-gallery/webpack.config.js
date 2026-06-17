const path = require("path");
const webpack = require("webpack");
const HtmlWebpackPlugin = require("html-webpack-plugin");
const CopyPlugin = require("copy-webpack-plugin");
const TerserPlugin = require("terser-webpack-plugin");

const isDevelopment = process.env.NODE_ENV !== "production";
const NETWORK = process.env.DFX_NETWORK || (isDevelopment ? "local" : "ic");
const TAGGR_DOMAIN = process.env.TAGGR_DOMAIN || "taggr.link";
let effectiveNetwork = NETWORK;

function getDfxPort() {
    try {
        const { execSync } = require("child_process");
        return execSync("dfx info webserver-port", {
            encoding: "utf8",
        }).trim();
    } catch (error) {
        return "8080";
    }
}

function initCanisterEnv() {
    let localCanisters, prodCanisters;
    const root = path.resolve(__dirname, "..", "..");
    try {
        localCanisters = require(path.join(root, ".dfx", "local", "canister_ids.json"));
    } catch (error) {
        console.log("No local canister_ids.json found. Continuing production");
    }
    try {
        prodCanisters = require(path.join(root, "canister_ids.json"));
    } catch (error) {
        console.log("No production canister_ids.json found. Continuing with local");
    }

    if (NETWORK === "local" && !localCanisters && prodCanisters) {
        effectiveNetwork = "ic";
    }

    const canisterConfig =
        effectiveNetwork === "local" ? localCanisters : prodCanisters;
    if (
        !canisterConfig ||
        !canisterConfig.taggr ||
        !canisterConfig.taggr[effectiveNetwork]
    ) {
        return {};
    }
    return { CANISTER_ID: canisterConfig.taggr[effectiveNetwork] };
}

const canisterEnvVariables = initCanisterEnv();

module.exports = {
    target: "web",
    mode: isDevelopment ? "development" : "production",
    entry: {
        gallery: path.join(__dirname, "src", "index.tsx"),
    },
    devtool: isDevelopment ? "source-map" : false,
    optimization: {
        minimize: !isDevelopment,
        minimizer: [
            new TerserPlugin({
                terserOptions: {
                    compress: {
                        drop_console: true,
                        dead_code: true,
                        passes: 2,
                    },
                    output: {
                        comments: false,
                    },
                },
                extractComments: false,
            }),
        ],
    },
    resolve: {
        extensions: [".js", ".ts", ".jsx", ".tsx"],
    },
    output: {
        filename: "[name].js",
        path: path.join(__dirname, "..", "..", "dist", "image-gallery"),
        clean: true,
    },
    module: {
        rules: [
            {
                test: /\.(ts|tsx|jsx)$/,
                loader: "ts-loader",
                exclude: [/node_modules/],
                options: {
                    configFile: path.join(__dirname, "tsconfig.json"),
                },
            },
        ],
    },
    plugins: [
        new HtmlWebpackPlugin({
            filename: "gallery.html",
            template: path.join(__dirname, "src", "index.html"),
            chunks: ["gallery"],
            cache: false,
            minify: isDevelopment
                ? false
                : {
                      minifyCSS: true,
                      collapseWhitespace: true,
                      keepClosingSlash: true,
                      removeComments: true,
                      removeRedundantAttributes: true,
                      removeScriptTypeAttributes: true,
                      removeStyleLinkTypeAttributes: true,
                      useShortDoctype: true,
                  },
        }),
        new CopyPlugin({
            patterns: [
                {
                    from: path.join(__dirname, "src", "style.css"),
                    to: path.join(__dirname, "..", "..", "dist", "image-gallery"),
                },
            ],
        }),
        new webpack.EnvironmentPlugin({
            DFX_NETWORK: effectiveNetwork,
            TAGGR_DOMAIN,
            CANISTER_ID: "",
            ...canisterEnvVariables,
        }),
    ],
    devServer: {
        port: 9091,
        host: "0.0.0.0",
        allowedHosts: "all",
        proxy: [
            {
                context: ["/api"],
                target: `http://127.0.0.1:${getDfxPort()}`,
                changeOrigin: true,
                pathRewrite: {
                    "^/api": "/api",
                },
            },
        ],
        hot: true,
        watchFiles: [path.resolve(__dirname, "src")],
        liveReload: true,
    },
};
