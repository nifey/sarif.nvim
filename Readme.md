# SARIF.nvim

A Neovim plugin for viewing [SARIF](https://sarifweb.azurewebsites.net/) formatted static analysis results. 

[SARIF](https://sarifweb.azurewebsites.net/) (Static Analysis Results Interchange Format) is an open standard for making results coming from static analysis tools to be interoperable. A few static analysis tools support SARIF output, while there exists many converters that convert other static analysis tool outputs into SARIF format (eg: [SARIF Multitool](https://github.com/microsoft/sarif-sdk/blob/main/docs/multitool-usage.md#supported-converters), [ESLint](https://www.npmjs.com/package/@microsoft/eslint-formatter-sarif), [axe](https://www.npmjs.com/package/axe-sarif-converter)).

There are extensions for VSCode for loading and viewing SARIF logs : [SARIF Viewer](https://github.com/Microsoft/sarif-vscode-extension/) & [SARIF Explorer](https://github.com/trailofbits/vscode-sarif-explorer). This plugin tries to do what these extensions do, but inside Neovim.

![Screenshot](screenshot.png)

### Features
1. Open SARIF files and list the results in a viewer
2. Classify results as True positive or False positive report, and also add comments to help during review.
3. Comments are stored in [SARIF Explorer](https://github.com/trailofbits/vscode-sarif-explorer)'s `.sarifexplorer` format ([specifications](https://github.com/trailofbits/vscode-sarif-explorer/blob/main/docs/sarif_explorer_spec.md)), and so the plugin is interoperable with SARIF explorer.

### Installation

Using [vim-plug](https://github.com/junegunn/vim-plug)

```viml
Plug 'nifey/sarif.nvim'
```

Using [dein](https://github.com/Shougo/dein.vim)

```viml
call dein#add('nifey/sarif.nvim')
```

Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  'nifey/sarif.nvim'
}
```

Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
-- init.lua:
    {
    'nifey/sarif.nvim'
    }
```

### Usage

The plugin provides two user commands `SarifLoad` to load a SARIF file, and `SarifView` to view the loaded results.
```
:SarifLoad <file.sarif>
:SarifView
```

When the SarifView window is open, the top window shows a table of results, where each row displays the file name and a short message about the error. The window on the bottom shows more information about the currently selected result including the rule, the SARIF log from which it was read, and the static analysis tool that created that report. When inside the SarifView window the following key bindings can be used:
- `j` and `k` to move between the results in the results table
- `<enter>` to go to the location of the currently selected bug report
- `l` to toggle the status of the result (True positive, False positive or None)
- `i` to update or insert a comment about a result

### Todo
- UI improvements
    - Scrolling support
    - Dynamic table resize
- Ability to sort, filter results based on file, category, bug status, etc
- Ability to traverse codeflows given in the SARIF logs
- Allow writing long-form comments rather than just a single line comment
- Handling more generic cases from SARIF Specifications
- Integrate with Nvim diagnostics to show the reports for the current file while editing
