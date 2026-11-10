module github.com/CruGlobal/cru-flags

// 1.25 for the ignore directive below. No requires, deliberately: the
// package is standard library only, so every app that imports it inherits
// nothing.
go 1.25

// The TypeScript client's dependencies; never Go packages.
ignore ./node_modules
