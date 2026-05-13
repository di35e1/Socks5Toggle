import SwiftUI
import Combine
import Foundation

// --- 1. ПРОСТОЙ ЛОГГЕР (Аналог python logging) ---
class AppLogger {
    static let shared = AppLogger()
    private let logFilePath = "/tmp/Socks5Toggle.log"
    private let dateFormatter: DateFormatter

    private init() {
        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        
        // Создаем файл лога, если его еще нет
        if !FileManager.default.fileExists(atPath: logFilePath) {
            FileManager.default.createFile(atPath: logFilePath, contents: nil, attributes: nil)
        }
    }

    func log(_ message: String, level: String = "INFO") {
        let timestamp = dateFormatter.string(from: Date())
        let logMessage = "\(timestamp) - \(level) - \(message)\n"
        
        // Дублируем в консоль Xcode для удобства разработки
        print(logMessage, terminator: "")
        
        // Записываем в конец файла
        if let fileHandle = FileHandle(forWritingAtPath: logFilePath) {
            fileHandle.seekToEndOfFile()
            if let data = logMessage.data(using: .utf8) {
                fileHandle.write(data)
            }
            try? fileHandle.close()
        }
    }

    func info(_ message: String) { log(message, level: "INFO") }
    func warning(_ message: String) { log(message, level: "WARNING") }
    func error(_ message: String) { log(message, level: "ERROR") }
}

// --- 2. ИНТЕРФЕЙС ПРИЛОЖЕНИЯ ---
@main
struct Socks5ToggleApp: App {
    @StateObject private var manager = ProxyManager()
    
    var body: some Scene {
        MenuBarExtra {
            
            if let interface = manager.interface {
                Text("Интерфейс: \(interface)")
                Divider()
                
                Button(manager.proxyEnabled ? "Выключить SOCKS5" : "Включить SOCKS5") {
                    manager.toggleProxy()
                }
            } else {
                Text("Нет сети")
                Button("Включить SOCKS5") {}
                    .disabled(true)
            }
            
            Divider()
            
            Button(manager.autostartEnabled ? "✓ Запускать при старте" : "Запускать при старте") {
                manager.toggleAutostart()
            }
            
            Divider()
            
            Button("Выход") {
                AppLogger.shared.info("Приложение Socks5Toggle завершило работу")
                NSApplication.shared.terminate(nil)
            }
            
        } label: {
            // Динамический текст со словом Proxy (без иконки глобуса)
            let statusText = manager.proxyEnabled ? "🟢 Proxy" : (manager.interface != nil ? "⚪️ Proxy" : "🔴 No network")
            Text(statusText)
        }
    }
}

// --- 3. ГЛАВНЫЙ КЛАСС ЛОГИКИ ---
class ProxyManager: ObservableObject {
    @Published var interface: String? = nil
    @Published var proxyEnabled: Bool = false
    @Published var autostartEnabled: Bool = false
    
    private var timer: Timer?
    private let plistPath = (NSHomeDirectory() as NSString).appendingPathComponent("Library/LaunchAgents/com.proxytoggle.app.plist")
    private var isFirstCheck = true
    
    init() {
        AppLogger.shared.info("Приложение Socks5Toggle запущено")
        self.autostartEnabled = FileManager.default.fileExists(atPath: plistPath)
        
        updateStatus()
        
        // Таймер проверки каждые 300 секунд (5 минут) как в Python коде
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.updateStatus(isTimerCheck: true)
        }
    }
    
    // --- ОСНОВНЫЕ ФУНКЦИИ ---
    
    func updateStatus(isTimerCheck: Bool = false) {
        DispatchQueue.global(qos: .userInitiated).async {
            let newInterface = self.getActiveNetworkService()
            let newProxyState = self.getProxyState(interface: newInterface)
            
            DispatchQueue.main.async {
                if !self.isFirstCheck {
                    // Логика проверок, в точности как была в Python:
                    if newInterface != self.interface {
                        if self.interface == nil && newInterface != nil {
                            AppLogger.shared.info("Сеть появилась. Активный интерфейс: \(newInterface!)")
                        } else if self.interface != nil && newInterface == nil {
                            AppLogger.shared.warning("Соединение с сетью потеряно (интерфейс \(self.interface!) отключен)")
                        } else if let oldInt = self.interface, let newInt = newInterface {
                            AppLogger.shared.info("Обнаружена смена интерфейса: \(oldInt) -> \(newInt)")
                        }
                    }
                    
                    if isTimerCheck && newProxyState != self.proxyEnabled {
                        let statusStr = newProxyState ? "включен" : "выключен"
                        AppLogger.shared.info("Статус прокси изменен извне (или из-за смены сети): \(statusStr)")
                    }
                }
                
                self.interface = newInterface
                self.proxyEnabled = newProxyState
                self.isFirstCheck = false
            }
        }
    }
    
    func toggleProxy() {
        guard let interface = interface else {
            AppLogger.shared.warning("Попытка переключить прокси при отсутствии сети")
            return
        }
        let newState = !proxyEnabled
        self.proxyEnabled = newState
        
        DispatchQueue.global(qos: .background).async {
            self.setProxyState(interface: interface, state: newState)
            AppLogger.shared.info("SOCKS5 \(newState ? "ВКЛЮЧЕН" : "ВЫКЛЮЧЕН") для интерфейса \(interface)")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.updateStatus()
            }
        }
    }
    
    func toggleAutostart() {
        let enable = !autostartEnabled
        let folderPath = (plistPath as NSString).deletingLastPathComponent
        
        if enable {
            do {
                try FileManager.default.createDirectory(atPath: folderPath, withIntermediateDirectories: true)
                guard let appPath = Bundle.main.executablePath else {
                    AppLogger.shared.error("Не удалось найти путь к .app файлу")
                    return
                }
                
                let plistContent: [String: Any] = [
                    "Label": "com.proxytoggle.app",
                    "ProgramArguments": [appPath],
                    "RunAtLoad": true,
                    "KeepAlive": ["SuccessfulExit": false]
                ]
                
                let plistData = try PropertyListSerialization.data(fromPropertyList: plistContent, format: .xml, options: 0)
                FileManager.default.createFile(atPath: plistPath, contents: plistData, attributes: nil)
                
                AppLogger.shared.info("Автозагрузка включена (создан файл \(plistPath))")
            } catch {
                AppLogger.shared.error("Ошибка создания автозагрузки: \(error)")
            }
        } else {
            if FileManager.default.fileExists(atPath: plistPath) {
                do {
                    try FileManager.default.removeItem(atPath: plistPath)
                    AppLogger.shared.info("Автозагрузка выключена (удален файл \(plistPath))")
                } catch {
                    AppLogger.shared.error("Ошибка удаления автозагрузки: \(error)")
                }
            }
        }
        
        self.autostartEnabled = enable
    }
    
    // --- ТЕРМИНАЛЬНЫЕ КОМАНДЫ И ПРОВЕРКА ОШИБОК ---
    
    // Функция теперь возвращает вывод команды и код ошибки (return code)
    private func shell(_ command: String) -> (output: String, status: Int32) {
        let task = Process()
        let pipe = Pipe()
        
        task.standardOutput = pipe
        task.standardError = pipe
        task.arguments = ["-c", command]
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.standardInput = nil

        do {
            try task.run()
            task.waitUntilExit() // Ждем завершения, чтобы получить код ошибки
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (output, task.terminationStatus)
        } catch {
            AppLogger.shared.error("Сбой системной команды '\(command)': \(error.localizedDescription)")
            return ("", -1)
        }
    }
    
    private func getActiveNetworkService() -> String? {
        let route = shell("route -n get default")
        // Если статус не 0, значит маршрута по умолчанию нет (нет интернета)
        if route.status != 0 { return nil }
        
        guard let interfaceLine = route.output.components(separatedBy: "\n").first(where: { $0.contains("interface:") }) else { return nil }
        
        let device = interfaceLine.replacingOccurrences(of: "interface:", with: "").trimmingCharacters(in: .whitespaces)
        if device.isEmpty { return nil }
        
        let hwPorts = shell("networksetup -listallhardwareports")
        let lines = hwPorts.output.components(separatedBy: "\n")
        
        for i in 0..<lines.count {
            if lines[i].contains("Device: \(device)") && i > 0 {
                let portLine = lines[i-1]
                if portLine.contains("Hardware Port:") {
                    return portLine.replacingOccurrences(of: "Hardware Port:", with: "").trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return nil
    }
    
    private func getProxyState(interface: String?) -> Bool {
        guard let interface = interface else { return false }
        let result = shell("networksetup -getsocksfirewallproxy \"\(interface)\"")
        return result.output.contains("Enabled: Yes")
    }
    
    private func setProxyState(interface: String, state: Bool) {
        let command = state ? "on" : "off"
        let result = shell("networksetup -setsocksfirewallproxystate \"\(interface)\" \(command)")
        
        // Логируем, если система не смогла поменять прокси
        if result.status != 0 {
            AppLogger.shared.error("Ошибка networksetup: \(result.output)")
        }
    }
}
