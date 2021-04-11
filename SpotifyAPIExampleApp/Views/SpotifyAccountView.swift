import SwiftUI
import SpotifyWebAPI
import SpotifyExampleContent
import Foundation

struct SpotifyAccountView: View {
    
    @EnvironmentObject var spotify: Spotify

    let account: SpotifyAccount
    
    init(account: SpotifyAccount) {
        self.account = account
    }

    var body: some View {
        Button(action: {
            spotify.currentAccount = account
            var accountCopy = account
            spotify.api.authorizationManager = accountCopy.authorizationManager
            spotify.accountsListViewIsPresented = false
        }, label: {
            HStack {
                Image(systemName: "checkmark")
                    .opacity(
                        spotify.currentAccount == account ? 100 : 0
                    )
                Text(account.user.displayName ?? account.user.id)
                    .contextMenu {
                        #if DEBUG
                        Button(action: {
                            print(self.account)
                        }, label: {
                            Text("print to the console")
                        })
                        #endif
                    }
            }
        })

    }
    
}

struct SpotifyAccountView_Previews: PreviewProvider {
    static var previews: some View {
        SpotifyAccountsListView_Previews.previews
    }
}
