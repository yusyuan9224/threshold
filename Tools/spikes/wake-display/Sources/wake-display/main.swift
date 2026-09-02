import Foundation
import IOKit.pwr_mgt
var id: IOPMAssertionID = 0
let r = IOPMAssertionDeclareUserActivity("Threshold SPIKE-003" as CFString, kIOPMUserActiveLocal, &id)
print("{\"kind\":\"wake\",\"result\":\(r),\"assertionID\":\(id),\"date\":\"\(Date())\"}")
