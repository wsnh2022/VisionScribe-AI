#SingleInstance Force
#Requires AutoHotkey v2.0+
~*^s:: Reload
Tray := A_TrayMenu, Tray.Delete(), Tray.AddStandard(), Tray.Add()
Tray.Add("Open Folder", (*) => Run(A_ScriptDir)), Tray.SetIcon("Open Folder", "shell32.dll", 5)

; -----------------

class ImageChat {
    ; --- Config (loaded from config.ini at startup) ---
    static ApiKey       := ""
    static ApiUrl       := ""
    static TesseractPath := ""
    static PyScript     := A_ScriptDir . "\InstaImage2TextConverter.py"

    ; Load config from ini on class init
    static __New() {
        iniPath := A_ScriptDir . "\config.ini"
        if (!FileExist(iniPath))
            MsgBox("config.ini not found in:`n" . A_ScriptDir . "`n`nPlease create it with [API] Key= and [Paths] TesseractExe=", "Missing Config", "Icon!")
        ImageChat.ApiKey        := IniRead(iniPath, "API",   "Key",          "")
        ImageChat.ApiUrl        := IniRead(iniPath, "API",   "Url",          "https://openrouter.ai/api/v1/chat/completions")
        ImageChat.TesseractPath := IniRead(iniPath, "Paths", "TesseractExe", "C:\Program Files\Tesseract-OCR\tesseract.exe")

        ; Load model list from [Models] section — numbered keys: 1_Label, 1_Id, 2_Label, 2_Id ...
        count := Integer(IniRead(iniPath, "Models", "Count", "0"))
        loop count {
            label := IniRead(iniPath, "Models", A_Index . "_Label", "")
            id    := IniRead(iniPath, "Models", A_Index . "_Id",    "")
            if (label != "" && id != "") {
                ImageChat.ModelLabels.Push(label)
                ImageChat.ModelMap[label] := id
            }
        }
        if (ImageChat.ModelLabels.Length = 0)
            MsgBox("No models found in config.ini [Models] section.`nAdd at least one model entry.", "Config Error", "Icon!")

        ; Restore last used folder across sessions
        ImageChat.LastFolder := IniRead(iniPath, "State", "LastFolder", "")

        ; Load prompt presets from [Prompts] section — numbered keys: 1_Title, 1_Text ...
        pcount := Integer(IniRead(iniPath, "Prompts", "Count", "0"))
        loop pcount {
            title := IniRead(iniPath, "Prompts", A_Index . "_Title", "")
            text  := IniRead(iniPath, "Prompts", A_Index . "_Text",  "")
            if (title != "" && text != "") {
                ImageChat.PromptTitles.Push(title)
                ImageChat.PromptTexts[title] := text
            }
        }
    }

    ; Populated dynamically from config.ini [Models] section in __New()
    static ModelLabels := []
    static ModelMap    := Map()

    ; Populated dynamically from config.ini [Prompts] section in __New()
    static PromptTitles := []
    static PromptTexts  := Map()

    ; --- GUI controls ---
    static Win          := unset
    static PathEdit     := unset
    static PromptEdit   := unset
    static OcrEdit      := unset
    static ResultEdit   := unset
    static ExtractBtn   := unset
    static DirectBtn    := unset  ; "Send Image Direct" — bypasses OCR, sends raw images to vision model
    static SendBtn      := unset
    static ModelDDL     := unset
    static PromptDDL    := unset  ; preset prompt selector — populated from config.ini [Prompts]
    static FallbackChk  := unset
    static StatusLbl    := unset

    ; --- State ---
    static SelectedFiles := []
    static LastFolder    := ""  ; persisted to config.ini [State] LastFolder


    static Build() {
        ImageChat.Win := Gui(, "AI Image To Text - v1.5")
        ImageChat.Win.BackColor := "1E1E1E"                     ; dark window background
        ImageChat.Win.SetFont("s10 cCCCCCC", "Segoe UI")        ; light text on dark bg
        ImageChat.Win.OnEvent("Close", (*) => ImageChat.Win.Destroy())

        ; --- Model row ---
        ImageChat.Win.Add("Text", "xm ym", "Model:")
        ImageChat.ModelDDL := ImageChat.Win.Add("DropDownList", "xm+50 yp-3 w320 Choose1", ImageChat.ModelLabels)
        ImageChat.FallbackChk := ImageChat.Win.Add("CheckBox", "x+10 yp+3 Checked cCCCCCC", "Auto Fallback")
        ; View Logs link — own line, right-aligned so it's always visible
        ImageChat.Win.Add("Link", "x390 y+6 w100 Right",
            '<a style="color:#6AABDB;font-size:8pt" href="https://openrouter.ai/logs">View Logs ↗</a>')

        ; --- File selection row ---
        ImageChat.Win.Add("Text", "xm y+6", "Files:")
        ImageChat.PathEdit := ImageChat.Win.Add("Edit", "xm+50 yp-3 w300 ReadOnly Background2D2D2D cCCCCCC")
        ImageChat.Win.Add("Button", "x+5 w60", "Browse")
            .OnEvent("Click", (*) => ImageChat.Browse())
        ImageChat.Win.Add("Button", "x+5 w60", "Clear")
            .OnEvent("Click", (*) => ImageChat.ClearAll())

        ; --- Step 1 ---
        ImageChat.Win.Add("Text", "xm y+12 c666666", "--- Step 1: OCR Extract  |  or Send Image Direct to skip OCR ---")
        ImageChat.ExtractBtn := ImageChat.Win.Add("Button", "xm y+6 w120", "OCR Extract")
        ImageChat.ExtractBtn.OnEvent("Click", (*) => ImageChat.ExtractOCR())
        ImageChat.DirectBtn := ImageChat.Win.Add("Button", "x+8 yp w140", "Send Image Direct")
        ImageChat.DirectBtn.OnEvent("Click", (*) => ImageChat.SendDirect())
        ImageChat.Win.Add("Button", "x+8 yp w90", "Save OCR")
            .OnEvent("Click", (*) => ImageChat.SaveOcr())
        ImageChat.Win.Add("Text", "xm y+8", "OCR Raw Output (editable):")
        ImageChat.OcrEdit := ImageChat.Win.Add("Edit", "xm y+4 w490 r7 Multi Background2D2D2D cCCCCCC")

        ; --- Step 2 ---
        ImageChat.Win.Add("Text", "xm y+12 c666666", "--- Step 2: Send to AI ---")

        ; Preset prompt selector — selecting immediately fills the prompt Edit box
        ImageChat.Win.Add("Text", "xm y+8", "Preset:")
        presetLabels := ["-- Select Preset Prompt --"]
        for t in ImageChat.PromptTitles
            presetLabels.Push(t)
        ImageChat.PromptDDL := ImageChat.Win.Add("DropDownList", "xm+55 yp-3 w425 Choose1", presetLabels)
        ImageChat.PromptDDL.OnEvent("Change", (*) => ImageChat.LoadPresetPrompt())

        ImageChat.Win.Add("Text", "xm y+8", "Prompt:")
        ImageChat.PromptEdit := ImageChat.Win.Add("Edit", "xm y+4 w490 r3 Background2D2D2D cCCCCCC",
            "Here is OCR-extracted text from one or more files. Organize and convert into clean Markdown "
            . "using proper headings, ordered sections, and full sentences. Fix broken lines. "
            . "Preserve original wording without adding or summarizing. Output only the final Markdown.")
        ImageChat.SendBtn := ImageChat.Win.Add("Button", "xm y+8 w110 Default", "OCR into AI")
        ImageChat.SendBtn.OnEvent("Click", (*) => ImageChat.Send())
        ImageChat.Win.Add("Button", "x+8 w110", "Copy Response")
            .OnEvent("Click", (*) => ImageChat.CopyResponse())
        ImageChat.Win.Add("Button", "x+8 w80", "Save .md")
            .OnEvent("Click", (*) => ImageChat.SaveMd())

        ImageChat.Win.Add("Text", "xm y+10", "AI Result:")
        ImageChat.ResultEdit := ImageChat.Win.Add("Edit", "xm y+4 w490 r10 Multi Background2D2D2D cCCCCCC")

        ; --- Status bar ---
        ImageChat.StatusLbl := ImageChat.Win.Add("Text", "xm y+8 w490 c666666", "Ready.")

        ImageChat.Win.Show("w510")


    }


    static SetStatus(msg) {
        ImageChat.StatusLbl.Value := msg
    }

    static Browse() {
        files := FileSelect("M 1", ImageChat.LastFolder, "Select Images or Text Files",
            "Supported Files (*.jpg;*.jpeg;*.png;*.bmp;*.tiff;*.gif;*.txt;*.md)")
        if (files.Length = 0)
            return
        ImageChat.SelectedFiles := files
        ; Persist the folder of the first selected file for next session
        ImageChat.LastFolder := SubStr(files[1], 1, InStr(files[1], "\", , -1) - 1)
        IniWrite(ImageChat.LastFolder, A_ScriptDir . "\config.ini", "State", "LastFolder")
        if (files.Length = 1)
            ImageChat.PathEdit.Value := files[1]
        else
            ImageChat.PathEdit.Value := files.Length . " files selected"
        ImageChat.SetStatus("Files loaded. Click OCR Extract or Send Image Direct.")
    }

    static ClearAll() {
        ImageChat.SelectedFiles  := []
        ImageChat.PathEdit.Value  := ""
        ImageChat.OcrEdit.Value   := ""
        ImageChat.ResultEdit.Value := ""
        ImageChat.SetStatus("Cleared.")
    }

    ; --- Step 1: OCR Extract or read text files ---
    static ExtractOCR() {
        files := ImageChat.SelectedFiles
        if (files.Length = 0)
            return MsgBox("Please select files first.", "No Files", "Icon!")

        ImageChat.ExtractBtn.Enabled := false
        ImageChat.SetStatus("Extracting... please wait.")

        imageFiles := []
        combined   := ""

        for f in files {
            ext := StrLower(SubStr(f, InStr(f, ".", , -1) + 1))
            if (ext = "txt" || ext = "md") {
                name := SubStr(f, InStr(f, "\", , -1) + 1)
                combined .= "`n--- " . name . " ---`n" . FileRead(f) . "`n"
            } else {
                imageFiles.Push(f)
            }
        }

        ; Run Python OCR on image files — pass TesseractExe path from config.ini
        if (imageFiles.Length > 0) {
            tmpOut := A_Temp . "\ahk_ocr_output.txt"
            args   := ""
            for f in imageFiles
                args .= ' "' . f . '"'
            cmd := 'python "' . ImageChat.PyScript . '"'
                 . ' --tesseract "' . ImageChat.TesseractPath . '"'
                 . args . ' > "' . tmpOut . '" 2>&1'
            RunWait("cmd.exe /c " . cmd, , "Hide")
            if (FileExist(tmpOut)) {
                combined .= FileRead(tmpOut)
                FileDelete(tmpOut)
            }
        }

        ImageChat.OcrEdit.Value  := Trim(combined)
        ImageChat.ExtractBtn.Enabled := true
        ImageChat.SetStatus("OCR complete. Review and edit the text above, then Send to AI.")
    }


    ; --- Step 2: Send OCR text to AI ---
    static Send() {
        ocrText := Trim(ImageChat.OcrEdit.Value)
        prompt  := Trim(ImageChat.PromptEdit.Value)

        if (ocrText = "")
            return MsgBox("OCR box is empty. Run OCR Extract first.", "No Content", "Icon!")
        if (prompt = "")
            return MsgBox("Please enter a prompt.", "Missing Prompt", "Icon!")

        ImageChat.SendBtn.Enabled  := false
        ImageChat.ResultEdit.Value := "Sending to AI..."
        ImageChat.SetStatus("Sending to AI...")

        try {
            selectedIdx   := ImageChat.ModelDDL.Value
            selectedLabel := ImageChat.ModelLabels[selectedIdx]
            selectedModel := ImageChat.ModelMap[selectedLabel]

            allModels := [selectedModel]
            if (ImageChat.FallbackChk.Value = 1) {
                for label in ImageChat.ModelLabels
                    if (label != selectedLabel)
                        allModels.Push(ImageChat.ModelMap[label])
            }

            lastError := ""
            for model in allModels {
                ImageChat.SetStatus("Trying: " . model . "...")
                body := ImageChat.BuildTextJson(ocrText, prompt, model)
                raw  := ImageChat.PostJson(body)
                if (InStr(raw, '"code":429') || InStr(raw, "Provider returned error")
                    || InStr(raw, "rate-limited") || InStr(raw, "No endpoints found")) {
                    lastError := raw
                    continue
                }
                result := ImageChat.ParseResponse(raw)
                ImageChat.ResultEdit.Value := "[" . model . "]`n`n" . result
                ImageChat.SetStatus("Done.")
                ImageChat.SendBtn.Enabled := true
                return
            }
            ImageChat.ResultEdit.Value := "All models failed.`n`n" . ImageChat.ParseResponse(lastError)
            ImageChat.SetStatus("All models rate-limited or unavailable.")
        } catch Error as e {
            ImageChat.ResultEdit.Value := "Error: " . e.Message
            ImageChat.SetStatus("Error occurred.")
        }

        ImageChat.SendBtn.Enabled := true
    }

    static CopyResponse() {
        text := ImageChat.ResultEdit.Value
        if (text = "" || text = "Sending to AI...")
            return MsgBox("Nothing to copy yet.", "Copy", "Icon!")
        A_Clipboard := text
        ToolTip "Copied to clipboard"
        SetTimer(() => ToolTip(), -1500)
    }

    static SaveMd() {
        text := ImageChat.ResultEdit.Value
        if (text = "" || text = "Sending to AI...")
            return MsgBox("No AI result to save yet.", "Save", "Icon!")

        savePath := ""
        if (ImageChat.SelectedFiles.Length > 0) {
            firstFile := ImageChat.SelectedFiles[1]
            dir       := SubStr(firstFile, 1, InStr(firstFile, "\", , -1) - 1)
            savePath  := dir . "\ai_output.md"
        }

        dest := FileSelect("S 8", savePath, "Save AI Result As", "Markdown (*.md)")
        if (dest = "")
            return
        if (!InStr(dest, "."))
            dest .= ".md"
        if (FileExist(dest))
            FileDelete(dest)
        FileAppend(text, dest, "UTF-8")
        ImageChat.SetStatus("Saved: " . dest)
        ToolTip "Saved to: " . dest
        SetTimer(() => ToolTip(), -2500)
    }


    ; --- Build plain-text JSON body (no image) ---
    static BuildTextJson(ocrText, prompt, model) {
        fullPrompt := prompt . "`n`n" . ocrText
        safe := StrReplace(fullPrompt, "\",  "\\")
        safe := StrReplace(safe, '"',  '\"')
        safe := StrReplace(safe, "`n", "\n")
        safe := StrReplace(safe, "`r", "\r")
        safe := StrReplace(safe, "`t", "\t")
        return '{"model":"' . model . '",'
             . '"messages":[{"role":"user","content":"' . safe . '"}]}'
    }

    ; --- POST JSON to OpenRouter ---
    static PostJson(body) {
        http := ComObject("WinHTTP.WinHTTPRequest.5.1")
        http.Open("POST", ImageChat.ApiUrl, false)
        http.SetRequestHeader("Content-Type",  "application/json")
        http.SetRequestHeader("Authorization", "Bearer " . ImageChat.ApiKey)
        http.SetRequestHeader("HTTP-Referer",  "https://ahk-tool.local")
        http.SetRequestHeader("X-Title",       "AHK Image Chat")
        http.Send(body)
        return ImageChat.DecodeUTF8(http.ResponseBody)
    }

    ; --- Decode COM SafeArray bytes as UTF-8 ---
    static DecodeUTF8(safeArray) {
        pSA := ComObjValue(safeArray)
        DllCall("oleaut32\SafeArrayGetLBound", "Ptr", pSA, "UInt", 1, "Int*", &lb := 0)
        DllCall("oleaut32\SafeArrayGetUBound", "Ptr", pSA, "UInt", 1, "Int*", &ub := 0)
        size := ub - lb + 1
        buf  := Buffer(size)
        DllCall("oleaut32\SafeArrayAccessData",   "Ptr", pSA, "Ptr*", &pData := 0)
        DllCall("RtlMoveMemory", "Ptr", buf, "Ptr", pData, "UPtr", size)
        DllCall("oleaut32\SafeArrayUnaccessData", "Ptr", pSA)
        return StrGet(buf, size, "UTF-8")
    }

    ; --- Extract assistant content from JSON response ---
    static ParseResponse(json) {
        assistantPos := InStr(json, '"role":"assistant"')
        if (!assistantPos)
            assistantPos := 1

        chunk := SubStr(json, assistantPos)
        if (RegExMatch(chunk, '"content"\s*:\s*"((?:[^"\\]|\\.)*)"', &m)) {
            text := m[1]
            text := StrReplace(text, "\\",  "\")
            text := StrReplace(text, "\n",  "`n")
            text := StrReplace(text, "\r",  "")
            text := StrReplace(text, "\t",  "`t")
            text := StrReplace(text, '\"',  '"')
            text := RegExReplace(text, "m)^#{1,6} ?", "")
            text := RegExReplace(text, "\*{1,3}(.*?)\*{1,3}", "$1")
            text := RegExReplace(text, "``+([^``]*)``+", "$1")
            text := RegExReplace(text, "m)^[-*] ", "- ")
            return text
        }

        if (RegExMatch(json, '"message"\s*:\s*"((?:[^"\\]|\\.)*)"', &m))
            return "API Error: " . m[1] . "`n`n--- Full Response ---`n" . json

        return "Could not parse response.`n`n--- Raw JSON ---`n" . json
    }

    ; --- Fill prompt Edit box from selected preset — index 1 is the placeholder, skip it ---
    static LoadPresetPrompt() {
        idx := ImageChat.PromptDDL.Value
        if (idx <= 1)  ; placeholder "-- Select Preset Prompt --" selected, do nothing
            return
        title := ImageChat.PromptTitles[idx - 1]  ; offset by 1 because DDL has placeholder at index 1
        ImageChat.PromptEdit.Value := ImageChat.PromptTexts[title]
    }

    ; --- Save OCR box contents to a user-chosen file ---
    static SaveOcr() {
        text := Trim(ImageChat.OcrEdit.Value)
        if (text = "")
            return MsgBox("OCR box is empty. Nothing to save.", "Save OCR", "Icon!")
        dest := FileSelect("S 8", ImageChat.LastFolder . "\ocr_output.txt",
            "Save OCR Text As", "Text Files (*.txt)|Markdown (*.md)")
        if (dest = "")
            return
        if (!InStr(dest, "."))
            dest .= ".txt"
        if (FileExist(dest))
            FileDelete(dest)
        FileAppend(text, dest, "UTF-8")
        ImageChat.SetStatus("OCR saved: " . dest)
        ToolTip "Saved: " . dest
        SetTimer(() => ToolTip(), -2500)
    }

    ; --- Send image files directly to a vision model via Python (handles base64 reliably) ---
    static SendDirect() {
        files  := ImageChat.SelectedFiles
        prompt := Trim(ImageChat.PromptEdit.Value)

        if (files.Length = 0)
            return MsgBox("Select files first.", "No Files", "Icon!")
        if (prompt = "")
            return MsgBox("Enter a prompt first.", "Missing Prompt", "Icon!")

        ; Filter to image files only — skip txt/md
        imgExts    := ["jpg","jpeg","png","bmp","gif","tiff","tif","webp"]
        imageFiles := []
        for f in files {
            ext := StrLower(SubStr(f, InStr(f, ".", , -1) + 1))
            for e in imgExts
                if (ext = e) {
                    imageFiles.Push(f)
                    break
                }
        }
        if (imageFiles.Length = 0)
            return MsgBox("No image files in selection.`nDirect mode requires at least one image file.", "No Images", "Icon!")

        ImageChat.DirectBtn.Enabled  := false
        ImageChat.ResultEdit.Value   := "Sending " . imageFiles.Length . " image(s) to AI..."
        ImageChat.SetStatus("Calling Python for direct vision — base64 + API handled by Python...")

        selectedIdx   := ImageChat.ModelDDL.Value
        selectedLabel := ImageChat.ModelLabels[selectedIdx]
        selectedModel := ImageChat.ModelMap[selectedLabel]

        ; Escape prompt for shell arg — wrap in double quotes, escape inner quotes
        safePrompt := StrReplace(prompt, '"', '\"')

        ; Build file args
        fileArgs := ""
        for f in imageFiles
            fileArgs .= ' "' . f . '"'

        tmpOut := A_Temp . "\ahk_direct_output.txt"
        cmd := 'python "' . ImageChat.PyScript . '"'
             . ' --direct'
             . ' --apikey "' . ImageChat.ApiKey . '"'
             . ' --apiurl "' . ImageChat.ApiUrl . '"'
             . ' --model "' . selectedModel . '"'
             . ' --prompt "' . safePrompt . '"'
             . fileArgs
             . ' > "' . tmpOut . '" 2>&1'

        RunWait("cmd.exe /c " . cmd, , "Hide")

        result := ""
        if (FileExist(tmpOut)) {
            result := Trim(FileRead(tmpOut))
            FileDelete(tmpOut)
        }

        if (result = "")
            result := "No output returned from Python."

        ImageChat.ResultEdit.Value := "[DIRECT VISION - " . selectedModel . "]`n`n" . result
        ImageChat.SetStatus("Done.")
        ImageChat.DirectBtn.Enabled := true
    }


}

ImageChat.Build()
