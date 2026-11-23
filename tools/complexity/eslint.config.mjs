// eslint's configuration for tools/complexity_check.sh: the sonarjs plugin's cognitive-complexity
// rule alone, at the limit the check passes in COMPLEXITY_LIMIT, over the files it names.
import sonarjs from "eslint-plugin-sonarjs";

export default [
  {
    files: ["**/*.js", "**/*.mjs"],
    languageOptions: { sourceType: "module" },
    plugins: { sonarjs },
    rules: { "sonarjs/cognitive-complexity": ["error", Number(process.env.COMPLEXITY_LIMIT)] },
  },
];
