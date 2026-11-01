@preconcurrency import Foundation

// MARK: - EC2 API Models

/// EC2 DescribeInstances response (JSON format)
struct EC2DescribeInstancesResponse: Codable, Sendable {
    let Reservations: [EC2Reservation]?
    let NextToken: String?
}

/// EC2 Reservation containing instances
struct EC2Reservation: Codable, Sendable {
    let ReservationId: String?
    let OwnerId: String?
    let Instances: [EC2Instance]?
}

/// EC2 Instance
struct EC2Instance: Codable, Sendable {
    let InstanceId: String
    let ImageId: String?
    let InstanceType: String?
    let State: EC2InstanceState?
    let PrivateIpAddress: String?
    let PublicIpAddress: String?
    let PrivateDnsName: String?
    let PublicDnsName: String?
    let Tags: [EC2Tag]?
    let LaunchTime: String?
    let Placement: EC2Placement?
    let VpcId: String?
    let SubnetId: String?
    let Architecture: String?
    let PlatformDetails: String?

    /// Get the Name tag value
    nonisolated var name: String? {
        Tags?.first { $0.Key == "Name" }?.Value
    }

    /// Convert to CloudInstance
    nonisolated func toCloudInstance(accountID: UUID) -> CloudInstance {
        let status: CloudInstanceStatus
        switch State?.Name?.lowercased() {
        case "running": status = .running
        case "stopped": status = .stopped
        case "pending": status = .provisioning
        case "stopping", "shutting-down": status = .rebooting
        case "terminated": status = .unknown
        default: status = .unknown
        }

        var instance = CloudInstance(
            id: UUID(),
            accountID: accountID,
            providerInstanceID: InstanceId,
            providerID: AWSProvider.providerID,
            label: name ?? InstanceId,
            status: status
        )

        // Extract region from availability zone (e.g., "us-east-1a" -> "us-east-1")
        if let az = Placement?.AvailabilityZone, !az.isEmpty {
            instance.region = String(az.dropLast())
        }
        instance.instanceType = InstanceType
        instance.image = ImageId
        instance.ipv4Address = PublicIpAddress
        instance.privateIP = PrivateIpAddress
        instance.hostname = PublicDnsName
        instance.tags = Tags?.compactMap { tag in
            guard let key = tag.Key, let value = tag.Value else { return nil }
            return "\(key):\(value)"
        } ?? []

        return instance
    }
}

/// EC2 Instance state
struct EC2InstanceState: Codable, Sendable {
    let Code: Int?
    let Name: String?
}

/// EC2 Tag
struct EC2Tag: Codable, Sendable {
    let Key: String?
    let Value: String?
}

/// EC2 Placement information
struct EC2Placement: Codable, Sendable {
    let AvailabilityZone: String?
    let Tenancy: String?
}

// MARK: - EKS API Models

/// EKS ListClusters response
struct EKSListClustersResponse: Sendable {
    let clusters: [String]?
    let nextToken: String?
}

extension EKSListClustersResponse: Decodable {
    private enum CodingKeys: String, CodingKey {
        case clusters, nextToken
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clusters = try container.decodeIfPresent([String].self, forKey: .clusters)
        nextToken = try container.decodeIfPresent(String.self, forKey: .nextToken)
    }
}

/// EKS DescribeCluster response
struct EKSDescribeClusterResponse: Sendable {
    let cluster: EKSCluster?
}

extension EKSDescribeClusterResponse: Decodable {
    private enum CodingKeys: String, CodingKey {
        case cluster
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cluster = try container.decodeIfPresent(EKSCluster.self, forKey: .cluster)
    }
}

/// EKS Cluster
struct EKSCluster: Sendable {
    let name: String?
    let arn: String?
    /// Seconds since 1970; EKS sends timestamps as JSON numbers
    let createdAt: Date?
    let version: String?
    let endpoint: String?
    let roleArn: String?
    let resourcesVpcConfig: EKSVpcConfig?
    let certificateAuthority: EKSCertificateAuthority?
    let status: String?
    let platformVersion: String?
    let tags: [String: String]?

    /// Convert to CloudKubernetesCluster
    nonisolated func toCloudKubernetesCluster(accountID: UUID, region: String) -> CloudKubernetesCluster {
        let clusterStatus: CloudClusterStatus
        switch status?.uppercased() {
        case "ACTIVE": clusterStatus = .ready
        case "CREATING": clusterStatus = .provisioning
        case "DELETING": clusterStatus = .deleting
        case "FAILED": clusterStatus = .notReady
        case "UPDATING": clusterStatus = .upgrading
        default: clusterStatus = .unknown
        }

        var cluster = CloudKubernetesCluster(
            id: UUID(),
            accountID: accountID,
            providerClusterID: arn ?? name ?? "",
            providerID: AWSProvider.providerID,
            label: name ?? "",
            status: clusterStatus
        )
        cluster.kubernetesVersion = version
        cluster.region = region
        cluster.apiEndpoint = endpoint
        cluster.nodeCount = 0 // EKS node counts require separate API calls
        cluster.highAvailability = true // EKS control plane is always HA
        cluster.tags = tags?.map { "\($0.key):\($0.value)" } ?? []
        cluster.isImported = false
        cluster.localClusterID = nil
        cluster.clusterARN = arn
        cluster.certificateAuthorityData = certificateAuthority?.data
        cluster.eksClusterName = name
        return cluster
    }
}

extension EKSCluster: Decodable {
    private enum CodingKeys: String, CodingKey {
        case name, arn, createdAt, version, endpoint, roleArn, resourcesVpcConfig, certificateAuthority, status, platformVersion, tags
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        arn = try container.decodeIfPresent(String.self, forKey: .arn)
        createdAt = try container.decodeIfPresent(Double.self, forKey: .createdAt)
            .map { Date(timeIntervalSince1970: $0) }
        version = try container.decodeIfPresent(String.self, forKey: .version)
        endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint)
        roleArn = try container.decodeIfPresent(String.self, forKey: .roleArn)
        resourcesVpcConfig = try container.decodeIfPresent(EKSVpcConfig.self, forKey: .resourcesVpcConfig)
        certificateAuthority = try container.decodeIfPresent(EKSCertificateAuthority.self, forKey: .certificateAuthority)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        platformVersion = try container.decodeIfPresent(String.self, forKey: .platformVersion)
        tags = try container.decodeIfPresent([String: String].self, forKey: .tags)
    }
}

/// EKS VPC configuration
struct EKSVpcConfig: Sendable {
    let subnetIds: [String]?
    let securityGroupIds: [String]?
    let clusterSecurityGroupId: String?
    let vpcId: String?
    let endpointPublicAccess: Bool?
    let endpointPrivateAccess: Bool?
    let publicAccessCidrs: [String]?
}

extension EKSVpcConfig: Decodable {
    private enum CodingKeys: String, CodingKey {
        case subnetIds, securityGroupIds, clusterSecurityGroupId, vpcId, endpointPublicAccess, endpointPrivateAccess, publicAccessCidrs
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        subnetIds = try container.decodeIfPresent([String].self, forKey: .subnetIds)
        securityGroupIds = try container.decodeIfPresent([String].self, forKey: .securityGroupIds)
        clusterSecurityGroupId = try container.decodeIfPresent(String.self, forKey: .clusterSecurityGroupId)
        vpcId = try container.decodeIfPresent(String.self, forKey: .vpcId)
        endpointPublicAccess = try container.decodeIfPresent(Bool.self, forKey: .endpointPublicAccess)
        endpointPrivateAccess = try container.decodeIfPresent(Bool.self, forKey: .endpointPrivateAccess)
        publicAccessCidrs = try container.decodeIfPresent([String].self, forKey: .publicAccessCidrs)
    }
}

/// EKS Certificate Authority
struct EKSCertificateAuthority: Sendable {
    let data: String?
}

extension EKSCertificateAuthority: Decodable {
    private enum CodingKeys: String, CodingKey {
        case data
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = try container.decodeIfPresent(String.self, forKey: .data)
    }
}

// MARK: - STS API Models

/// STS GetCallerIdentity response
struct STSGetCallerIdentityResponse: Codable, Sendable {
    let GetCallerIdentityResponse: STSGetCallerIdentityResult?
}

/// STS GetCallerIdentity result wrapper
struct STSGetCallerIdentityResult: Codable, Sendable {
    let GetCallerIdentityResult: STSCallerIdentity?
}

/// STS Caller Identity
struct STSCallerIdentity: Codable, Sendable {
    let Arn: String?
    let UserId: String?
    let Account: String?
}

// MARK: - AWS SSO OIDC API Models

/// SSO OIDC RegisterClient response
struct SSORegisterClientResponse: Sendable {
    let clientId: String
    let clientSecret: String
    let clientIdIssuedAt: Int
    let clientSecretExpiresAt: Int
}

extension SSORegisterClientResponse: Decodable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clientId = try container.decode(String.self, forKey: .clientId)
        clientSecret = try container.decode(String.self, forKey: .clientSecret)
        clientIdIssuedAt = try container.decode(Int.self, forKey: .clientIdIssuedAt)
        clientSecretExpiresAt = try container.decode(Int.self, forKey: .clientSecretExpiresAt)
    }

    private enum CodingKeys: String, CodingKey {
        case clientId, clientSecret, clientIdIssuedAt, clientSecretExpiresAt
    }
}

/// SSO OIDC StartDeviceAuthorization response
struct SSODeviceAuthorizationResponse: Sendable {
    let deviceCode: String
    let userCode: String
    let verificationUri: String
    let verificationUriComplete: String?
    let expiresIn: Int
    let interval: Int
}

extension SSODeviceAuthorizationResponse: Decodable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceCode = try container.decode(String.self, forKey: .deviceCode)
        userCode = try container.decode(String.self, forKey: .userCode)
        verificationUri = try container.decode(String.self, forKey: .verificationUri)
        verificationUriComplete = try container.decodeIfPresent(String.self, forKey: .verificationUriComplete)
        expiresIn = try container.decode(Int.self, forKey: .expiresIn)
        interval = try container.decode(Int.self, forKey: .interval)
    }

    private enum CodingKeys: String, CodingKey {
        case deviceCode, userCode, verificationUri, verificationUriComplete, expiresIn, interval
    }
}

/// SSO OIDC CreateToken response
struct SSOTokenResponse: Sendable {
    let accessToken: String
    let tokenType: String
    let expiresIn: Int
    let refreshToken: String?
    let idToken: String?
}

extension SSOTokenResponse: Decodable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decode(String.self, forKey: .accessToken)
        tokenType = try container.decode(String.self, forKey: .tokenType)
        expiresIn = try container.decode(Int.self, forKey: .expiresIn)
        refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
        idToken = try container.decodeIfPresent(String.self, forKey: .idToken)
    }

    private enum CodingKeys: String, CodingKey {
        case accessToken, tokenType, expiresIn, refreshToken, idToken
    }
}

/// SSO OIDC Error response
struct SSOOIDCError: Sendable {
    let error: String
    let error_description: String?
}

extension SSOOIDCError: Decodable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        error = try container.decode(String.self, forKey: .error)
        error_description = try container.decodeIfPresent(String.self, forKey: .error_description)
    }

    private enum CodingKeys: String, CodingKey {
        case error, error_description
    }
}

// MARK: - AWS SSO Portal API Models

/// SSO Portal ListAccounts response
struct SSOListAccountsResponse: Sendable {
    let accountList: [SSOAccountInfo]?
    let nextToken: String?
}

extension SSOListAccountsResponse: Decodable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountList = try container.decodeIfPresent([SSOAccountInfo].self, forKey: .accountList)
        nextToken = try container.decodeIfPresent(String.self, forKey: .nextToken)
    }

    private enum CodingKeys: String, CodingKey {
        case accountList, nextToken
    }
}

/// SSO Account info
struct SSOAccountInfo: Sendable {
    let accountId: String
    let accountName: String
    let emailAddress: String?

    nonisolated func toAWSSSOAccount() -> AWSSSOAccount {
        AWSSSOAccount(
            accountId: accountId,
            accountName: accountName,
            emailAddress: emailAddress
        )
    }
}

extension SSOAccountInfo: Decodable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountId = try container.decode(String.self, forKey: .accountId)
        accountName = try container.decode(String.self, forKey: .accountName)
        emailAddress = try container.decodeIfPresent(String.self, forKey: .emailAddress)
    }

    private enum CodingKeys: String, CodingKey {
        case accountId, accountName, emailAddress
    }
}

/// SSO Portal ListAccountRoles response
struct SSOListAccountRolesResponse: Sendable {
    let roleList: [SSORoleInfo]?
    let nextToken: String?
}

extension SSOListAccountRolesResponse: Decodable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        roleList = try container.decodeIfPresent([SSORoleInfo].self, forKey: .roleList)
        nextToken = try container.decodeIfPresent(String.self, forKey: .nextToken)
    }

    private enum CodingKeys: String, CodingKey {
        case roleList, nextToken
    }
}

/// SSO Role info
struct SSORoleInfo: Sendable {
    let roleName: String
    let accountId: String

    nonisolated func toAWSSSORole() -> AWSSSORole {
        AWSSSORole(roleName: roleName, accountId: accountId)
    }
}

extension SSORoleInfo: Decodable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        roleName = try container.decode(String.self, forKey: .roleName)
        accountId = try container.decode(String.self, forKey: .accountId)
    }

    private enum CodingKeys: String, CodingKey {
        case roleName, accountId
    }
}

/// SSO Portal GetRoleCredentials response
struct SSOGetRoleCredentialsResponse: Sendable {
    let roleCredentials: SSORoleCredentials
}

extension SSOGetRoleCredentialsResponse: Decodable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        roleCredentials = try container.decode(SSORoleCredentials.self, forKey: .roleCredentials)
    }

    private enum CodingKeys: String, CodingKey {
        case roleCredentials
    }
}

/// SSO Role credentials
struct SSORoleCredentials: Sendable {
    let accessKeyId: String
    let secretAccessKey: String
    let sessionToken: String
    let expiration: Int64

    nonisolated func toAWSSTSCredentials() -> AWSSTSCredentials {
        AWSSTSCredentials(
            accessKeyId: accessKeyId,
            secretAccessKey: secretAccessKey,
            sessionToken: sessionToken,
            expiration: Date(timeIntervalSince1970: TimeInterval(expiration / 1000))
        )
    }
}

extension SSORoleCredentials: Decodable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessKeyId = try container.decode(String.self, forKey: .accessKeyId)
        secretAccessKey = try container.decode(String.self, forKey: .secretAccessKey)
        sessionToken = try container.decode(String.self, forKey: .sessionToken)
        expiration = try container.decode(Int64.self, forKey: .expiration)
    }

    private enum CodingKeys: String, CodingKey {
        case accessKeyId, secretAccessKey, sessionToken, expiration
    }
}

// MARK: - EC2 XML Parser

/// Parser for EC2 DescribeInstances XML response
class EC2DescribeInstancesXMLParser: NSObject, XMLParserDelegate, @unchecked Sendable {
    private let xml: String
    private nonisolated(unsafe) var reservations: [EC2Reservation] = []
    private nonisolated(unsafe) var currentReservation: EC2ReservationBuilder?
    private nonisolated(unsafe) var currentInstance: EC2InstanceBuilder?
    private nonisolated(unsafe) var currentTag: EC2TagBuilder?
    private nonisolated(unsafe) var currentText = ""
    private nonisolated(unsafe) var nextToken: String?

    // Track element path to handle nested items correctly
    private nonisolated(unsafe) var elementStack: [String] = []

    nonisolated init(xml: String) {
        self.xml = xml
    }

    nonisolated func parse() -> EC2DescribeInstancesResponse {
        guard let data = xml.data(using: .utf8) else {
            return EC2DescribeInstancesResponse(Reservations: [], NextToken: nil)
        }

        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()

        return EC2DescribeInstancesResponse(Reservations: reservations, NextToken: nextToken)
    }

    /// Check if we're directly inside a specific parent element
    private nonisolated func isDirectlyInside(_ parent: String) -> Bool {
        guard elementStack.count >= 2 else { return false }
        return elementStack[elementStack.count - 2] == parent
    }

    /// Check if an element exists anywhere in our current path
    private nonisolated func isInside(_ element: String) -> Bool {
        elementStack.contains(element)
    }

    nonisolated func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        elementStack.append(elementName)
        currentText = ""

        switch elementName {
        case "item":
            // Only create objects for items directly inside specific sets
            if isDirectlyInside("reservationSet") {
                currentReservation = EC2ReservationBuilder()
            } else if isDirectlyInside("instancesSet") {
                currentInstance = EC2InstanceBuilder()
            } else if isDirectlyInside("tagSet") && isInside("instancesSet") {
                currentTag = EC2TagBuilder()
            }
        default:
            break
        }
    }

    nonisolated func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    nonisolated func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch elementName {
        case "item":
            if isDirectlyInside("tagSet") && isInside("instancesSet") {
                // Closing a tag item
                if let tag = currentTag {
                    currentInstance?.tags.append(EC2Tag(Key: tag.key, Value: tag.value))
                }
                currentTag = nil
            } else if isDirectlyInside("instancesSet") {
                // Closing an instance item
                if let instance = currentInstance, !instance.instanceId.isEmpty {
                    currentReservation?.instances.append(instance.build())
                }
                currentInstance = nil
            } else if isDirectlyInside("reservationSet") {
                // Closing a reservation item
                if let reservation = currentReservation?.build() {
                    reservations.append(reservation)
                }
                currentReservation = nil
            }

        // Reservation fields - only when directly in reservation context
        case "reservationId" where isInside("reservationSet") && !isInside("instancesSet"):
            currentReservation?.reservationId = text
        case "ownerId" where isDirectlyInside("item") && isInside("reservationSet") && !isInside("instancesSet"):
            currentReservation?.ownerId = text

        // Instance fields - only when in instance context
        case "instanceId" where isInside("instancesSet") && !isInside("networkInterfaceSet"):
            currentInstance?.instanceId = text
        case "imageId" where isInside("instancesSet"):
            currentInstance?.imageId = text
        case "instanceType" where isInside("instancesSet") && !isInside("placement"):
            currentInstance?.instanceType = text
        case "privateIpAddress" where isDirectlyInside("item") && isInside("instancesSet") && !isInside("networkInterfaceSet"):
            currentInstance?.privateIpAddress = text
        case "ipAddress" where isDirectlyInside("item") && isInside("instancesSet") && !isInside("networkInterfaceSet"):
            currentInstance?.publicIpAddress = text
        case "privateDnsName" where isDirectlyInside("item") && isInside("instancesSet") && !isInside("networkInterfaceSet"):
            currentInstance?.privateDnsName = text
        case "dnsName" where isDirectlyInside("item") && isInside("instancesSet") && !isInside("networkInterfaceSet"):
            currentInstance?.publicDnsName = text
        case "launchTime" where isInside("instancesSet"):
            currentInstance?.launchTime = text
        case "vpcId" where isDirectlyInside("item") && isInside("instancesSet") && !isInside("networkInterfaceSet"):
            currentInstance?.vpcId = text
        case "subnetId" where isDirectlyInside("item") && isInside("instancesSet") && !isInside("networkInterfaceSet"):
            currentInstance?.subnetId = text
        case "architecture" where isInside("instancesSet"):
            currentInstance?.architecture = text
        case "platformDetails" where isInside("instancesSet"):
            currentInstance?.platformDetails = text

        // State fields
        case "code" where isInside("instanceState"):
            currentInstance?.stateCode = Int(text)
        case "name" where isInside("instanceState"):
            currentInstance?.stateName = text

        // Placement fields
        case "availabilityZone" where isInside("placement"):
            currentInstance?.availabilityZone = text
        case "tenancy" where isInside("placement"):
            currentInstance?.tenancy = text

        // Tag fields - only for instance tags
        case "key" where isInside("tagSet") && isInside("instancesSet") && currentTag != nil:
            currentTag?.key = text
        case "value" where isInside("tagSet") && isInside("instancesSet") && currentTag != nil:
            currentTag?.value = text

        // Pagination
        case "nextToken":
            nextToken = text.isEmpty ? nil : text

        default:
            break
        }

        currentText = ""
        elementStack.removeLast()
    }
}

// MARK: - Builder Classes for XML Parsing

private class EC2ReservationBuilder: @unchecked Sendable {
    nonisolated(unsafe) var reservationId: String?
    nonisolated(unsafe) var ownerId: String?
    nonisolated(unsafe) var instances: [EC2Instance] = []

    nonisolated init() {}

    nonisolated func build() -> EC2Reservation {
        EC2Reservation(
            ReservationId: reservationId,
            OwnerId: ownerId,
            Instances: instances.isEmpty ? nil : instances
        )
    }
}

private class EC2InstanceBuilder: @unchecked Sendable {
    nonisolated(unsafe) var instanceId: String = ""
    nonisolated(unsafe) var imageId: String?
    nonisolated(unsafe) var instanceType: String?
    nonisolated(unsafe) var stateCode: Int?
    nonisolated(unsafe) var stateName: String?
    nonisolated(unsafe) var privateIpAddress: String?
    nonisolated(unsafe) var publicIpAddress: String?
    nonisolated(unsafe) var privateDnsName: String?
    nonisolated(unsafe) var publicDnsName: String?
    nonisolated(unsafe) var launchTime: String?
    nonisolated(unsafe) var availabilityZone: String?
    nonisolated(unsafe) var tenancy: String?
    nonisolated(unsafe) var vpcId: String?
    nonisolated(unsafe) var subnetId: String?
    nonisolated(unsafe) var architecture: String?
    nonisolated(unsafe) var platformDetails: String?
    nonisolated(unsafe) var tags: [EC2Tag] = []

    nonisolated init() {}

    nonisolated func build() -> EC2Instance {
        EC2Instance(
            InstanceId: instanceId,
            ImageId: imageId,
            InstanceType: instanceType,
            State: EC2InstanceState(Code: stateCode, Name: stateName),
            PrivateIpAddress: privateIpAddress,
            PublicIpAddress: publicIpAddress,
            PrivateDnsName: privateDnsName,
            PublicDnsName: publicDnsName,
            Tags: tags.isEmpty ? nil : tags,
            LaunchTime: launchTime,
            Placement: EC2Placement(AvailabilityZone: availabilityZone, Tenancy: tenancy),
            VpcId: vpcId,
            SubnetId: subnetId,
            Architecture: architecture,
            PlatformDetails: platformDetails
        )
    }
}

private class EC2TagBuilder: @unchecked Sendable {
    nonisolated(unsafe) var key: String?
    nonisolated(unsafe) var value: String?

    nonisolated init() {}
}

// MARK: - EC2 DescribeImages Models

/// EC2 DescribeImages response
struct EC2DescribeImagesResponse: Sendable {
    let images: [EC2Image]
}

/// EC2 Image (AMI)
struct EC2Image: Sendable {
    let imageId: String
    let name: String?
    let description: String?
    let platformDetails: String?
}

/// Parser for EC2 DescribeImages XML response
class EC2DescribeImagesXMLParser: NSObject, XMLParserDelegate, @unchecked Sendable {
    private let xml: String
    private nonisolated(unsafe) var images: [EC2Image] = []
    private nonisolated(unsafe) var currentImage: EC2ImageBuilder?
    private nonisolated(unsafe) var currentText = ""
    private nonisolated(unsafe) var elementStack: [String] = []

    nonisolated init(xml: String) {
        self.xml = xml
    }

    nonisolated func parse() -> EC2DescribeImagesResponse {
        guard let data = xml.data(using: .utf8) else {
            return EC2DescribeImagesResponse(images: [])
        }

        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()

        return EC2DescribeImagesResponse(images: images)
    }

    private nonisolated func isDirectlyInside(_ parent: String) -> Bool {
        guard elementStack.count >= 2 else { return false }
        return elementStack[elementStack.count - 2] == parent
    }

    nonisolated func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        elementStack.append(elementName)
        currentText = ""

        if elementName == "item" && isDirectlyInside("imagesSet") {
            currentImage = EC2ImageBuilder()
        }
    }

    nonisolated func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    nonisolated func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch elementName {
        case "item" where isDirectlyInside("imagesSet"):
            if let image = currentImage, !image.imageId.isEmpty {
                images.append(image.build())
            }
            currentImage = nil
        case "imageId" where currentImage != nil:
            currentImage?.imageId = text
        case "name" where currentImage != nil:
            currentImage?.name = text
        case "description" where currentImage != nil:
            currentImage?.imageDescription = text
        case "platformDetails" where currentImage != nil:
            currentImage?.platformDetails = text
        default:
            break
        }

        currentText = ""
        elementStack.removeLast()
    }
}

private class EC2ImageBuilder: @unchecked Sendable {
    nonisolated(unsafe) var imageId: String = ""
    nonisolated(unsafe) var name: String?
    nonisolated(unsafe) var imageDescription: String?
    nonisolated(unsafe) var platformDetails: String?

    nonisolated init() {}

    nonisolated func build() -> EC2Image {
        EC2Image(
            imageId: imageId,
            name: name,
            description: imageDescription,
            platformDetails: platformDetails
        )
    }
}
