import Foundation
#if os(macOS)
    import PostboxMac
    import SwiftSignalKitMac
#else
    import Postbox
    import SwiftSignalKit
#endif

public enum EnqueueMessage {
    case message(text: String, attributes: [MessageAttribute], media: Media?, replyToMessageId: MessageId?)
    case forward(source: MessageId)
    
    public func withUpdatedReplyToMessageId(_ replyToMessageId: MessageId?) -> EnqueueMessage {
        switch self {
            case let .message(text, attributes, media, _):
                return .message(text: text, attributes: attributes, media: media, replyToMessageId: replyToMessageId)
            case .forward:
                return self
        }
    }
}

private func filterMessageAttributesForOutgoingMessage(_ attributes: [MessageAttribute]) -> [MessageAttribute] {
    return attributes.filter { attribute in
        switch attribute {
            case let _ as TextEntitiesMessageAttribute:
                return true
            case let _ as InlineBotMessageAttribute:
                return true
            case let _ as OutgoingMessageInfoAttribute:
                return true
            case let _ as ReplyMarkupMessageAttribute:
                return true
            case let _ as OutgoingChatContextResultMessageAttribute:
                return true
            default:
                return false
        }
    }
}

private func filterMessageAttributesForForwardedMessage(_ attributes: [MessageAttribute]) -> [MessageAttribute] {
    return attributes.filter { attribute in
        switch attribute {
            case let _ as TextEntitiesMessageAttribute:
                return true
            case let _ as InlineBotMessageAttribute:
                return true
            default:
                return false
        }
    }
}

public func enqueueMessages(account: Account, peerId: PeerId, messages: [EnqueueMessage]) -> Signal<Void, NoError> {
    return account.postbox.modify { modifier -> Void in
        enqueueMessages(modifier: modifier, account: account, peerId: peerId, messages: messages)
    }
}

func enqueueMessages(modifier: Modifier, account: Account, peerId: PeerId, messages: [EnqueueMessage]) {
    if let peer = modifier.getPeer(peerId) {
        var storeMessages: [StoreMessage] = []
        let timestamp = Int32(account.network.context.globalTime())
        for message in messages {
            var attributes: [MessageAttribute] = []
            var flags = StoreMessageFlags()
            flags.insert(.Unsent)
            
            var randomId: Int64 = 0
            arc4random_buf(&randomId, 8)
            attributes.append(OutgoingMessageInfoAttribute(uniqueId: randomId))
            
            switch message {
                case let .message(text, requestedAttributes, media, replyToMessageId):
                    if let peer = peer as? TelegramSecretChat {
                        var isAction = false
                        if let _ = media as? TelegramMediaAction {
                            isAction = true
                        }
                        if let messageAutoremoveTimeout = peer.messageAutoremoveTimeout, !isAction {
                            attributes.append(AutoremoveTimeoutMessageAttribute(timeout: messageAutoremoveTimeout, countdownBeginTime: nil))
                        }
                    }
                    
                    attributes.append(contentsOf: filterMessageAttributesForOutgoingMessage(requestedAttributes))
                        
                    if let replyToMessageId = replyToMessageId {
                        attributes.append(ReplyMessageAttribute(messageId: replyToMessageId))
                    }
                    var mediaList: [Media] = []
                    if let media = media {
                        mediaList.append(media)
                    }
                
                    storeMessages.append(StoreMessage(peerId: peerId, namespace: Namespaces.Message.Local, globallyUniqueId: randomId, timestamp: timestamp, flags: flags, tags: tagsForStoreMessage(mediaList), forwardInfo: nil, authorId: account.peerId, text: text, attributes: attributes, media: mediaList))
                case let .forward(source):
                    if let sourceMessage = modifier.getMessage(source), let author = sourceMessage.author {
                        if let peer = peer as? TelegramSecretChat {
                            var isAction = false
                            for media in sourceMessage.media {
                                if let _ = media as? TelegramMediaAction {
                                    isAction = true
                                    break
                                }
                            }
                            if let messageAutoremoveTimeout = peer.messageAutoremoveTimeout, !isAction {
                                attributes.append(AutoremoveTimeoutMessageAttribute(timeout: messageAutoremoveTimeout, countdownBeginTime: nil))
                            }
                        }
                        
                        attributes.append(ForwardSourceInfoAttribute(messageId: sourceMessage.id))
                        attributes.append(contentsOf: filterMessageAttributesForForwardedMessage(sourceMessage.attributes))
                        let forwardInfo: StoreMessageForwardInfo
                        if let sourceForwardInfo = sourceMessage.forwardInfo {
                            forwardInfo = StoreMessageForwardInfo(authorId: sourceForwardInfo.author.id, sourceId: sourceForwardInfo.source?.id, sourceMessageId: sourceForwardInfo.sourceMessageId, date: sourceForwardInfo.date)
                        } else {
                            forwardInfo = StoreMessageForwardInfo(authorId: author.id, sourceId: nil, sourceMessageId: nil, date: sourceMessage.timestamp)
                        }
                        storeMessages.append(StoreMessage(peerId: peerId, namespace: Namespaces.Message.Local, globallyUniqueId: randomId, timestamp: timestamp, flags: flags, tags: tagsForStoreMessage(sourceMessage.media), forwardInfo: forwardInfo, authorId: account.peerId, text: sourceMessage.text, attributes: attributes, media: sourceMessage.media))
                    }
            }
        }
        if !storeMessages.isEmpty {
            modifier.addMessages(storeMessages, location: .Random)
        }
    }
}
