//  Licensed to the Apache Software Foundation (ASF) under one
//  or more contributor license agreements.  See the NOTICE file
//  distributed with this work for additional information
//  regarding copyright ownership.  The ASF licenses this file
//  to you under the Apache License, Version 2.0 (the
//  "License"); you may not use this file except in compliance
//  with the License.  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing,
//  software distributed under the License is distributed on an
//  "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
//  KIND, either express or implied.  See the License for the
//  specific language governing permissions and limitations
//  under the License.

import Foundation
import GRDB

struct DeviceRecord: Codable, FetchableRecord, MutablePersistableRecord {
  static let databaseTableName = "device"
  var id: Int64?
  var uuid: String
  var name: String
  var updateSequenceNumber: Int64

  static func createV1Table(in database: Database) throws {
    try database.create(table: "device", body: { table in
      table.autoIncrementedPrimaryKey("id")
      table.column("uuid", .text).notNull().unique().indexed()
      table.column("name", .text).notNull()
      table.column("updateSequenceNumber", .integer).notNull()
    })
  }

  enum Columns {
    static let uuid = Column(DeviceRecord.CodingKeys.uuid)
  }

  mutating func didInsert(with rowID: Int64, for column: String?) {
    id = rowID
  }
}