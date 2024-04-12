module.exports = {
  verbose: true,
  collectCoverage: true,
  coverageDirectory: "./coverage",
  moduleDirectories: ["node_modules"],
  transform: {
    ".(ts|tsx|js|jsx)": "ts-jest",
  },
  roots: ["<rootDir>"],
  moduleFileExtensions: ["ts", "tsx", "js", "jsx"],
};
