//
//  SplashScreenView.swift
//  PodiatryAR
//
//  Created by Mann Fam on 7/14/26.
//

import SwiftUI

struct SplashScreenView: View {

    var body: some View {
        ZStack {
            Color.splashBackdrop
                .ignoresSafeArea()
            VStack(spacing: 18) {
                Image("3dFormulaLogo")
                    .resizable()
                    .scaledToFit()
            }
        }
    }
}

#Preview {
    SplashScreenView()
}
