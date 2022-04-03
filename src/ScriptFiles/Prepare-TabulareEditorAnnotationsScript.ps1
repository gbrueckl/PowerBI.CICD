Param (
    [parameter(Mandatory = $true)] [String] $TabularEditorRootPath
)
# we need to set Serialization Options to allow export to Folder via TE2
$serialization_options = '{
    "IgnoreInferredObjects": true,
    "IgnoreInferredProperties": true,
    "IgnoreTimestamps": true,
    "SplitMultilineStrings": true,
    "PrefixFilenames": false,
    "LocalTranslations": false,
    "LocalPerspectives": false,
    "LocalRelationships": false,
    "Levels": [
        "Data Sources",
        "Perspectives",
        "Relationships",
        "Roles",
        "Tables",
        "Tables/Columns",
        "Tables/Measures",
        "Translations"
    ]
}'

$serialization_options | Out-File (Join-Path $TabularEditorRootPath "TabularEditor_SerializeOptions.json")

"Model.SetAnnotation(""TabularEditor_SerializeOptions"", ReadFile(@""$(Join-Path $TabularEditorRootPath "TabularEditor_SerializeOptions.json")""));" `
	| Out-File (Join-Path $TabularEditorrootPath "ApplySerializeOptionsAnnotation.csx")

return "-SCRIPT ""$(Join-Path $TabularEditorRootPath 'ApplySerializeOptionsAnnotation.csx')"""