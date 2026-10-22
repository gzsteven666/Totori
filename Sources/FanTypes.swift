import SwiftUI

// MARK: - 外观

enum FanTheme: String, CaseIterable, Identifiable {
    case forest // 森林凝胶 · 嫩叶绿（当前默认）
    case haze   // 晨雾蓝 · 30% 天蓝 + 70% 透明
    case aqua   // 玻璃蓝
    case mint   // 玻璃绿

    var id: String { rawValue }

    var title: String {
        switch self {
        case .forest: return "森林绿"
        case .haze: return "晨雾蓝"
        case .aqua: return "玻璃蓝"
        case .mint: return "玻璃绿"
        }
    }

    var tint: Color {
        switch self {
        case .forest: return Palette.brand
        case .haze: return Color(red: 0.38, green: 0.74, blue: 0.95)
        case .aqua: return Color(red: 0.24, green: 0.60, blue: 1.00)
        case .mint: return Color(red: 0.16, green: 0.86, blue: 0.62)
        }
    }

    var tintLight: Color {
        switch self {
        case .forest: return Palette.glassTop
        case .haze: return Color(red: 0.90, green: 0.98, blue: 1.00)
        case .aqua: return Color(red: 0.55, green: 0.86, blue: 1.00)
        case .mint: return Color(red: 0.58, green: 0.98, blue: 0.72)
        }
    }

    /// 玻璃体渐变（品牌玻璃材质），与用于文字/选中的 tint 分开
    var glassTop: Color {
        switch self {
        case .forest: return Palette.glassTop
        case .haze: return Color(red: 0.85, green: 0.96, blue: 1.00)
        case .aqua: return Color(red: 0.55, green: 0.86, blue: 1.00)
        case .mint: return Color(red: 0.58, green: 0.98, blue: 0.72)
        }
    }

    var glassBottom: Color {
        switch self {
        case .forest: return Palette.glassBottom
        case .haze: return Color(red: 0.56, green: 0.80, blue: 0.88)
        case .aqua: return Color(red: 0.24, green: 0.60, blue: 1.00)
        case .mint: return Color(red: 0.16, green: 0.86, blue: 0.62)
        }
    }

    /// 浅色玻璃上用的文字色
    var ink: Color {
        switch self {
        case .forest: return Palette.textPrimary
        case .haze: return Color(red: 0.06, green: 0.26, blue: 0.40)
        case .aqua: return Color(red: 0.05, green: 0.18, blue: 0.34)
        case .mint: return Color(red: 0.04, green: 0.26, blue: 0.20)
        }
    }

    /// 选中花瓣的实心填充（强调色到悬停色）与其上的前景，所有主题共用，和主窗口按钮同一套取色。
    var hotTop: Color { Palette.brand }
    var hotBottom: Color { Palette.brandHover }
    var hotInk: Color { Palette.onAccent }

    var gradient: LinearGradient {
        LinearGradient(
            colors: [tintLight, tint],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - 三种滚轮

enum FanMode: String, CaseIterable, Identifiable {
    case convert, tools, actions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .convert: return "转换格式"
        case .tools:   return "文件工具"
        case .actions: return "文件动作"
        }
    }

    var keyHint: String {
        KeyMap.effectiveKey(for: self)?.symbol ?? "—"
    }
}

enum ToolKind: String, CaseIterable, Identifiable {
    case cropImage, redactImage, compressImage, rotateRight, resizeSmall, stripMetadata, toPDF, mergePDF, splitPDF, zipArchive, qrText, trimMedia

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cropImage:     return "裁剪"
        case .redactImage:   return "标注"
        case .compressImage: return "压缩图片"
        case .rotateRight:   return "右转 90°"
        case .stripMetadata: return "去元数据"
        case .mergePDF:      return "合并 PDF"
        case .splitPDF:      return "拆分 PDF"
        case .toPDF:         return "转成 PDF"
        case .zipArchive:    return "打包 ZIP"
        case .qrText:        return "识别二维码"
        case .trimMedia:     return "修剪"
        case .resizeSmall:   return "缩到一半"
        }
    }

    var hint: String {
        switch self {
        case .cropImage:     return "拖框选取"
        case .redactImage:   return "涂黑 / 画笔"
        case .compressImage: return "画质换体积"
        case .rotateRight:   return "顺时针"
        case .stripMetadata: return "抹掉 EXIF"
        case .mergePDF:      return "多份并一份"
        case .splitPDF:      return "一页一个"
        case .toPDF:         return "单页 PDF"
        case .zipArchive:    return "压缩包"
        case .qrText:        return "读内容并复制"
        case .trimMedia:     return "选区间截取"
        case .resizeSmall:   return "边长 50%"
        }
    }
}

enum ActionKind: String, CaseIterable, Identifiable {
    case airDrop, copy, move, copyPath, terminal, reveal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .airDrop:  return "隔空投送"
        case .copy:     return "拷贝"
        case .move:     return "移动"
        case .copyPath: return "拷贝路径"
        case .terminal: return "终端"
        case .reveal:   return "在访达"
        }
    }

    var hint: String {
        switch self {
        case .airDrop:  return "发到附近设备"
        case .copy:     return "到剪贴板"
        case .move:     return "到下载文件夹"
        case .copyPath: return "POSIX 路径"
        case .terminal: return "打开所在目录"
        case .reveal:   return "显示位置"
        }
    }
}

/// 滚轮上的一项
enum FanItem: Identifiable, Hashable {
    case format(OutputFormat)
    case tool(ToolKind)
    case action(ActionKind)
    case moreFormats(FileKind)

    var id: String {
        switch self {
        case .format(let f): return "f.\(f.id)"
        case .tool(let t):   return "t.\(t.id)"
        case .action(let a): return "a.\(a.id)"
        case .moreFormats(let kind): return "more.\(kind.rawValue)"
        }
    }

    static func symbol(for format: OutputFormat) -> String {
        switch format.ext {
        case "mp4", "mov", "mkv", "webm", "avi", "wmv", "m4v":
            return "film"
        case "gif":
            return "rectangle.stack.badge.play"
        case "mp3", "m4a", "wav", "flac", "aiff", "ogg", "opus", "wma":
            return "music.note"
        case "png", "jpg", "heic", "tiff", "webp":
            return "photo"
        case "pdf":
            return "doc.richtext"
        case "html":
            return "globe"
        case "txt", "rtf", "docx", "odt":
            return "doc.text"
        case "zip":
            return "archivebox"
        default:
            return "arrow.triangle.2.circlepath"
        }
    }

    var title: String {
        switch self {
        case .format(let f): return f.name
        case .tool(let t):   return t.title
        case .action(let a): return a.title
        case .moreFormats: return "更多"
        }
    }

    var hint: String {
        switch self {
        case .format(let f): return f.hint
        case .tool(let t):   return t.hint
        case .action(let a): return a.hint
        case .moreFormats: return "松手后选择其他格式"
        }
    }

    var symbol: String {
        switch self {
        case .format(let f):     return FanItem.symbol(for: f)
        case .moreFormats:      return "ellipsis.circle"
        case .tool(let t):
            switch t {
            case .cropImage:     return "crop"
            case .redactImage:   return "rectangle.fill"
            case .compressImage: return "arrow.down.right.and.arrow.up.left"
            case .rotateRight:   return "rotate.right"
            case .stripMetadata: return "eye.slash"
            case .toPDF:         return "doc.richtext"
            case .mergePDF:      return "doc.on.doc.fill"
            case .splitPDF:      return "scissors"
            case .zipArchive:    return "archivebox"
            case .qrText:        return "qrcode.viewfinder"
            case .trimMedia:     return "scissors"
            case .resizeSmall:   return "arrow.down.left.and.arrow.up.right"
            }
        case .action(let a):
            switch a {
            case .airDrop:  return "antenna.radiowaves.left.and.right"
            case .copy:     return "doc.on.doc"
            case .move:     return "folder"
            case .copyPath: return "link"
            case .terminal: return "terminal"
            case .reveal:   return "magnifyingglass"
            }
        }
    }
}

