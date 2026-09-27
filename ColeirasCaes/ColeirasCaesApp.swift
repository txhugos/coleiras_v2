import SwiftUI
import CoreBluetooth
import CoreLocation
import MapKit

private enum BLE {
    static let service = CBUUID(string: "d62a0001-7d50-48ab-93d8-6080f2ccaa01")
    static let dog01 = CBUUID(string: "d62a0002-7d50-48ab-93d8-6080f2ccaa01")
    static let dog02 = CBUUID(string: "d62a0003-7d50-48ab-93d8-6080f2ccaa01")
}

struct DogRecord: Decodable, Identifiable {
    let id: String
    let seq: Int?
    let lat: Double?
    let lon: Double?
    let speed: Double?
    let sat: Int?
    let satUso: Int?
    let satIds: String?
    let batV: Double?
    let batPct: Int?
    let rssi: Double?
    let snr: Double?
    let receivedAt: Int?

    enum CodingKeys: String, CodingKey {
        case id, seq, lat, lon, speed, sat, rssi, snr
        case satUso = "sat_uso", satIds = "sat_ids"
        case batV = "bat_v", batPct = "bat_pct"
        case receivedAt = "received_at"
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let lat, let lon, (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    var isRecent: Bool {
        guard let receivedAt else { return false }
        return abs(Date().timeIntervalSince1970 - Double(receivedAt)) < 30
    }
}

@MainActor final class CollarBluetooth: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var status = "A iniciar Bluetooth…"
    @Published var dogs: [String: DogRecord] = [:]
    private var manager: CBCentralManager!
    private var raspberry: CBPeripheral?
    private var positions: [CBCharacteristic] = []
    private var pollTimer: Timer?

    override init() {
        super.init()
        manager = CBCentralManager(delegate: self, queue: .main)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            status = "A procurar Raspberry…"
            central.scanForPeripherals(withServices: [BLE.service])
        } else {
            status = "Ativa o Bluetooth do iPhone"
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard raspberry == nil else { return }
        raspberry = peripheral
        peripheral.delegate = self
        status = "A ligar a \(peripheral.name ?? "ColeirasCaes")…"
        central.stopScan()
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        status = "Ligado ao Raspberry"
        peripheral.discoverServices([BLE.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        reconnect(central)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        reconnect(central)
    }

    private func reconnect(_ central: CBCentralManager) {
        pollTimer?.invalidate()
        pollTimer = nil
        raspberry = nil
        positions = []
        status = "Ligação perdida. A procurar Raspberry…"
        if central.state == .poweredOn { central.scanForPeripherals(withServices: [BLE.service]) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == BLE.service }) else {
            status = "Serviço das coleiras não encontrado"
            return
        }
        peripheral.discoverCharacteristics([BLE.dog01, BLE.dog02], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        positions = (service.characteristics ?? []).filter { $0.uuid == BLE.dog01 || $0.uuid == BLE.dog02 }
        guard !positions.isEmpty else { status = "Dados BLE não encontrados"; return }
        readPositions()
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.readPositions()
        }
    }

    private func readPositions() {
        guard let raspberry else { return }
        for characteristic in positions { raspberry.readValue(for: characteristic) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        do {
            let dog = try JSONDecoder().decode(DogRecord.self, from: data)
            dogs[dog.id] = dog
        } catch {
            status = "Erro ao ler dados: \(error.localizedDescription)"
        }
    }
}

@MainActor final class PhoneLocation: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var coordinate: CLLocationCoordinate2D?
    @Published var denied = false
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func start() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
        case .denied, .restricted:
            denied = true
        @unknown default:
            break
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { start() }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        coordinate = locations.last?.coordinate
    }
}

struct ContentView: View {
    @StateObject private var bluetooth = CollarBluetooth()
    @StateObject private var phoneLocation = PhoneLocation()
    @State private var camera: MapCameraPosition = .region(
        MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 39.5, longitude: -8.0),
                           span: MKCoordinateSpan(latitudeDelta: 5, longitudeDelta: 5)))
    @State private var following = true
    @State private var lastPositionKey = ""
    @State private var selectedDog: String?
    @State private var trails: [String: [CLLocationCoordinate2D]] = [:]

    private var positionedDogs: [DogRecord] {
        ["DOG01", "DOG02"].compactMap { bluetooth.dogs[$0] }.filter { $0.coordinate != nil }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    mapPanel
                    HStack(spacing: 12) {
                        Button {
                            selectedDog = nil
                            following = true
                            frameDogs()
                        } label: {
                            Label("Ver ambas", systemImage: "square.dashed.inset.filled")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        Button {
                            following.toggle()
                            if following { frameDogs() }
                        } label: {
                            Label(following ? "A seguir" : "Seguir", systemImage: following ? "location.fill" : "location")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .font(.subheadline)

                    Button {
                        if let coordinate = phoneLocation.coordinate {
                            following = false
                            camera = .region(MKCoordinateRegion(
                                center: coordinate,
                                span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)))
                        } else {
                            phoneLocation.start()
                        }
                    } label: {
                        Label("Minha posição", systemImage: "location.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    if phoneLocation.denied {
                        Text("Para mostrar a tua posição, permite o acesso à localização nas Definições do iPhone.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text("COLEIRAS")
                        .font(.caption.weight(.bold))
                        .tracking(2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    ForEach(["DOG01", "DOG02"], id: \.self) { id in
                        dogCard(id, record: bluetooth.dogs[id])
                    }
                    Text("Posições recebidas por LoRa e Bluetooth. As ruas do mapa podem precisar de internet; sem rede, as coordenadas continuam disponíveis.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Coleiras")
            .onAppear { phoneLocation.start() }
            .onReceive(bluetooth.$dogs) { records in
                let key = ["DOG01", "DOG02"].compactMap { id -> String? in
                    guard let dog = records[id], let coordinate = dog.coordinate else { return nil }
                    return "\(id):\(coordinate.latitude):\(coordinate.longitude)"
                }.joined(separator: "|")
                guard !key.isEmpty, key != lastPositionKey else { return }
                lastPositionKey = key
                for id in ["DOG01", "DOG02"] {
                    guard let coordinate = records[id]?.coordinate else { continue }
                    var trail = trails[id] ?? []
                    if let previous = trail.last,
                       previous.latitude == coordinate.latitude,
                       previous.longitude == coordinate.longitude { continue }
                    trail.append(coordinate)
                    trails[id] = Array(trail.suffix(100))
                }
                if following { frameDogs(records) }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(.blue.gradient, in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 3) {
                Text("Localização em direto").font(.headline)
                Text(bluetooth.status).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Circle()
                .fill(bluetooth.status == "Ligado ao Raspberry" ? .green : .orange)
                .frame(width: 10, height: 10)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private var mapPanel: some View {
        Map(position: $camera) {
            UserAnnotation()
            ForEach(["DOG01", "DOG02"], id: \.self) { id in
                if let trail = trails[id], trail.count > 1 {
                    MapPolyline(coordinates: trail)
                        .stroke(dogColor(id), lineWidth: 3)
                }
            }
            ForEach(positionedDogs) { dog in
                if let coordinate = dog.coordinate {
                    Annotation(dog.id, coordinate: coordinate, anchor: .bottom) {
                        Button {
                            selectedDog = dog.id
                            following = true
                            frameDogs()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "pawprint.fill")
                                Text(dog.id).fontWeight(.bold)
                            }
                            .font(.subheadline)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 8)
                            .background(dog.isRecent ? dogColor(dog.id) : .gray,
                                        in: Capsule())
                            .shadow(radius: 3)
                        }
                    }
                }
            }
        }
        .frame(height: 440)
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(alignment: .topLeading) {
            if positionedDogs.isEmpty {
                Label("À espera de coordenadas GPS", systemImage: "location.slash")
                    .font(.subheadline.weight(.semibold))
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding(12)
            }
        }
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 9) {
                Label("DOG01", systemImage: "pawprint.fill").foregroundStyle(.blue)
                Label("DOG02", systemImage: "pawprint.fill").foregroundStyle(.orange)
                Text("Cinzento: antiga").foregroundStyle(.secondary)
            }
                .font(.caption2.bold())
                .padding(9)
                .background(.regularMaterial, in: Capsule())
                .padding(12)
        }
    }

    private func frameDogs(_ data: [String: DogRecord]? = nil) {
        let visible = ["DOG01", "DOG02"].compactMap { (data ?? bluetooth.dogs)[$0] }
            .filter { $0.coordinate != nil }
        let records = selectedDog.map { id in visible.filter { $0.id == id } } ?? visible
        let coordinates = records.compactMap(\.coordinate)
        guard !coordinates.isEmpty else { return }
        let latitudes = coordinates.map(\.latitude)
        let longitudes = coordinates.map(\.longitude)
        guard let minLat = latitudes.min(), let maxLat = latitudes.max(),
              let minLon = longitudes.min(), let maxLon = longitudes.max() else { return }
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                           longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: max(0.008, (maxLat - minLat) * 1.8),
                                   longitudeDelta: max(0.008, (maxLon - minLon) * 1.8)))
        withAnimation(.easeInOut(duration: 0.6)) { camera = .region(region) }
    }

    private func dogColor(_ id: String) -> Color { id == "DOG01" ? .blue : .orange }

    private func dogCard(_ id: String, record: DogRecord?) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 10) {
                Image(systemName: "pawprint.fill")
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(dogColor(id), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 2) {
                    Text(id).font(.headline)
                    Text(record.map { $0.isRecent ? "Posição recente" : "Último sinal antigo" } ?? "A aguardar sinal")
                        .font(.caption)
                    .foregroundStyle(record?.isRecent == true ? Color.green : Color.secondary)
                }
                Spacer()
                if record?.coordinate != nil {
                    Button {
                        selectedDog = id
                        following = true
                        frameDogs()
                    } label: {
                        Image(systemName: "scope")
                            .font(.title3)
                            .frame(width: 42, height: 42)
                    }
                    .accessibilityLabel("Centrar mapa em \(id)")
                }
            }
            if let record {
                if let coordinate = record.coordinate {
                    Text(String(format: "%.6f, %.6f", coordinate.latitude, coordinate.longitude))
                        .font(.system(.subheadline, design: .monospaced))
                        .textSelection(.enabled)
                    Button("Abrir no Mapas") {
                        let place = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
                        place.name = id
                        place.openInMaps()
                    }
                    .font(.subheadline)
                } else {
                    Label("À espera de posição GPS", systemImage: "location.slash")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    metric("Satélites", record.sat.map(String.init) ?? "—", "sparkles")
                    metric("Em uso", record.satUso.map(String.init) ?? "—", "location")
                    metric("Bateria", record.batPct.map { "\($0)%" } ?? "—", "battery.75percent")
                }
                HStack(spacing: 6) {
                    metric("Tensão", record.batV.map { String(format: "%.2f V", $0) } ?? "—", "bolt")
                    metric("Sinal LoRa", record.rssi.map { String(format: "%.0f dBm", $0) } ?? "—", "antenna.radiowaves.left.and.right")
                    metric("Velocidade", record.speed.map { String(format: "%.1f", $0) } ?? "—", "speedometer")
                }
                if let receivedAt = record.receivedAt {
                    Text("Última receção: \(Date(timeIntervalSince1970: Double(receivedAt)), format: .dateTime.day().month().hour().minute().second())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let ids = record.satIds, ids != "NA", !ids.isEmpty {
                    Text("Satélites: \(ids)").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("À espera de mensagens desta coleira")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private func metric(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(systemName: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.bold()).lineLimit(1).minimumScaleFactor(0.65)
            Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
    }
}

@main struct ColeirasCaesApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
