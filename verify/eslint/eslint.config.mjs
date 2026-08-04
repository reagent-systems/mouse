export default [
  {
    files: ["src/**/*.js"],
    languageOptions: { ecmaVersion: 2022, sourceType: "commonjs" },
    rules: {
      "no-unused-vars": "error",
      "no-undef": "error",
      "eqeqeq": "warn",
      "no-empty": "warn",
    },
  },
];
