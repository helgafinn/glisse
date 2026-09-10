//
//  main.swift
//  Glisse
//
//  Entry point. Deliberately tiny: everything lives in GlisseKit so the
//  logic is unit-testable.
//
//  Modes:
//    (no args)    normal menu-bar app
//    --diagnose   terminal tool that prints live normalised touch frames
//    --probe      one-shot capability report (devices, displays, audio, HUD)
//    --version
//

import GlisseKit
import Foundation

GlisseMain.run(arguments: CommandLine.arguments)
