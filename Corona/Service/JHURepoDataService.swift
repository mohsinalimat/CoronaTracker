//
//  DataService.swift
//  Corona Tracker
//
//  Created by Mohammad on 3/10/20.
//  Copyright © 2020 Samabox. All rights reserved.
//

import Foundation

import Disk
import CSV

class JHURepoDataService: DataService {
	enum FetchError: Error {
		case tooOldData
		case noNewData
		case invalidData
		case downloadError
	}

	static let instance = JHURepoDataService()

	private static let maxOldDataAge = 10 // Days
	private static let dailyReportFileName = "JHURepoDataService-DailyReport.csv"
	private static let confirmedTimeSeriesFileName = "JHURepoDataService-TS-Confirmed.csv"
	private static let recoveredTimeSeriesFileName = "JHURepoDataService-TS-Recovered.csv"
	private static let deathsTimeSeriesFileName = "JHURepoDataService-TS-Deaths.csv"

	private static let baseURL = URL(string: "https://github.com/CSSEGISandData/COVID-19/raw/master/csse_covid_19_data/")!
	private static let dailyReportURLString = "csse_covid_19_daily_reports/%@.csv"
	private static let confirmedTimeSeriesURL = URL(string: "csse_covid_19_time_series/time_series_19-covid-Confirmed.csv", relativeTo: baseURL)!
	private static let recoveredTimeSeriesURL = URL(string: "csse_covid_19_time_series/time_series_19-covid-Recovered.csv", relativeTo: baseURL)!
	private static let deathsTimeSeriesURL = URL(string: "csse_covid_19_time_series/time_series_19-covid-Deaths.csv", relativeTo: baseURL)!

	func fetchReports(completion: @escaping FetchReportsBlock) {
		let today = Date()
		downloadDailyReport(date: today, completion: completion)
	}

	private func downloadDailyReport(date: Date, completion: @escaping FetchReportsBlock) {
		if date.ageDays > Self.maxOldDataAge {
			completion(nil, FetchError.tooOldData)
			return
		}

		let formatter = DateFormatter()
		formatter.locale = .posix
		formatter.dateFormat = "MM-dd-YYYY"
		let fileName = formatter.string(from: date)

		print("Downloading \(fileName)")
		let url = URL(string: String(format: Self.dailyReportURLString, fileName), relativeTo: Self.baseURL)!

		_ = URLSession.shared.dataTask(with: url) { (data, response, error) in

			guard let response = response as? HTTPURLResponse,
				response.statusCode == 200,
				let data = data else {

					print("Failed downloading \(fileName)")
					self.downloadDailyReport(date: date.yesterday, completion: completion)
					return
			}

			DispatchQueue.global(qos: .default).async {
				let oldData = try? Disk.retrieve(Self.dailyReportFileName, from: .caches, as: Data.self)
				if (oldData == data) {
					print("Nothing new")
					completion(nil, FetchError.noNewData)
					return
				}

				print("Download success \(fileName)")
				try? Disk.save(data, to: .caches, as: Self.dailyReportFileName)

				self.parseReports(data: data, completion: completion)
			}
		}.resume()
	}

	private func parseReports(data: Data, completion: @escaping FetchReportsBlock) {
		do {
			let reader = try CSVReader(string: String(data: data, encoding: .utf8)!, hasHeaderRow: true)
			let reports = reader.map({ Report.create(dataRow: $0) })
			completion(reports, nil)
		}
		catch {
			print("Unexpected error: \(error).")
			completion(nil, error)
		}
	}

	func fetchTimeSerieses(completion: @escaping FetchTimeSeriesesBlock) {
		let dispatchGroup = DispatchGroup()
		var result = [Data?](repeating: nil, count: 3)

		dispatchGroup.enter()
		downloadFile(url: Self.confirmedTimeSeriesURL, fileName: Self.confirmedTimeSeriesFileName) { data in
			result[0] = data
			dispatchGroup.leave()
		}

		dispatchGroup.enter()
		downloadFile(url: Self.recoveredTimeSeriesURL, fileName: Self.recoveredTimeSeriesFileName) { data in
			result[1] = data
			dispatchGroup.leave()
		}

		dispatchGroup.enter()
		downloadFile(url: Self.deathsTimeSeriesURL, fileName: Self.deathsTimeSeriesFileName) { data in
			result[2] = data
			dispatchGroup.leave()
		}

		dispatchGroup.notify(queue: .main) {
			let result = result.compactMap { $0 }
			if result.count != 3 {
				completion(nil, FetchError.downloadError)
				return
			}

			DispatchQueue.global(qos: .default).async {
				self.parseTimeSerieses(data: result, completion: completion)
			}
		}
	}

	private func parseTimeSerieses(data: [Data], completion: @escaping FetchTimeSeriesesBlock) {
		assert(data.count == 3)

		/// All time serieses
		guard let (confirmed, headers) = parseTimeSeries(data: data[0]) else {
			completion(nil, FetchError.invalidData)
			return
		}

		guard let (recovered, _) = parseTimeSeries(data: data[1]) else {
			completion(nil, FetchError.invalidData)
			return
		}

		guard let (deaths, _) = parseTimeSeries(data: data[2]) else {
			completion(nil, FetchError.invalidData)
			return
		}

		let dateFormatter = DateFormatter()
		dateFormatter.locale = .posix
		dateFormatter.dateFormat = "M/d/yy"

		let dateStrings = headers.dropFirst(4)

		var timeSerieses: [TimeSeries] = []
		for row in confirmed.indices {
			let confirmedTimeSeries = confirmed[row]
			let recoveredTimeSeries = recovered[row]
			let deathsTimeSeries = deaths[row]

			var series: [Date : Statistic] = [:]
			for column in confirmedTimeSeries.values.indices {
				let dateString = dateStrings[dateStrings.startIndex + column]
				if let date = dateFormatter.date(from: dateString) {
					let stat = Statistic(
						confirmedCount: confirmedTimeSeries.values[column],
						recoveredCount: recoveredTimeSeries.values[column],
						deathCount: deathsTimeSeries.values[column]
					)
					series[date] = stat
				}
			}
			let timeSeries = TimeSeries(region: confirmedTimeSeries.region, series: series)
			timeSerieses.append(timeSeries)
		}
		completion(timeSerieses, nil)
	}

	private func parseTimeSeries(data: Data) -> (rows: [CounterTimeSeries], headers: [String])? {
		do {
			let reader = try CSVReader(string: String(data: data, encoding: .utf8)!, hasHeaderRow: true)
			let headers = reader.headerRow
			let result = reader.map({ CounterTimeSeries(dataRow: $0) })
			
			return (result, headers ?? [])
		}
		catch {
			print("Unexpected error: \(error).")
			return nil
		}
	}

	private func downloadFile(url: URL, fileName: String, completion: @escaping (Data?) -> ()) {
		print("Downloading \(fileName)")
		_ = URLSession.shared.dataTask(with: url) { (data, response, error) in
			guard let response = response as? HTTPURLResponse,
				response.statusCode == 200,
				let data = data else {

					print("Failed downloading \(fileName)")
					completion(nil)
					return
			}

			DispatchQueue.global().async {
				print("Download success \(fileName)")
				try? Disk.save(data, to: .caches, as: fileName)

				completion(data)
			}
		}.resume()
	}
}

extension Report {
	private enum DataFieldOrder: Int {
		case province = 0
		case country
		case lastUpdate
		case confirmed
		case deaths
		case recovered
		case latitude
		case longitude
	}

	static func create(dataRow: [String]) -> Report {
		let province = dataRow[DataFieldOrder.province.rawValue]
		let country = dataRow[DataFieldOrder.country.rawValue]
		let latitude = Double(dataRow[DataFieldOrder.latitude.rawValue]) ?? 0
		let longitude = Double(dataRow[DataFieldOrder.longitude.rawValue]) ?? 0
		let location = Coordinate(latitude: latitude, longitude: longitude)
		let region = Region(countryName: country, provinceName: province, location: location)

		let timeString = dataRow[DataFieldOrder.lastUpdate.rawValue]
		let formatter = ISO8601DateFormatter()
		formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
		let lastUpdate = formatter.date(from: timeString) ?? Date()

		let confirmed = Int(dataRow[DataFieldOrder.confirmed.rawValue]) ?? 0
		let deaths = Int(dataRow[DataFieldOrder.deaths.rawValue]) ?? 0
		let recovered = Int(dataRow[DataFieldOrder.recovered.rawValue]) ?? 0
		let stat = Statistic(confirmedCount: confirmed, recoveredCount: recovered, deathCount: deaths)

		return Report(region: region, lastUpdate: lastUpdate, stat: stat)
	}
}

private class CounterTimeSeries {
	private enum DataFieldOrder: Int {
		case province = 0
		case country
		case latitude
		case longitude
	}

	let region: Region
	let values: [Int]

	init(dataRow: [String]) {
		let province = dataRow[DataFieldOrder.province.rawValue]
		let country = dataRow[DataFieldOrder.country.rawValue]
		let latitude = Double(dataRow[DataFieldOrder.latitude.rawValue]) ?? 0
		let longitude = Double(dataRow[DataFieldOrder.longitude.rawValue]) ?? 0
		let location = Coordinate(latitude: latitude, longitude: longitude)
		self.region = Region(countryName: country, provinceName: province, location: location)

		self.values = dataRow.dropFirst(DataFieldOrder.longitude.rawValue + 1).map { Int($0) ?? 0 }
	}
}
