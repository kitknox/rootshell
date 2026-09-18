//
//  MuxDetachBannerState.swift
//  rootshell
//
//  Transient banner after mux detach (or when focusing an already-live
//  attachment) with an optional Reconnect action.
//

import Foundation

struct MuxDetachBannerState: Equatable {
    let message: String
    let offer: MuxSessionResume.ReconnectOffer?
}
