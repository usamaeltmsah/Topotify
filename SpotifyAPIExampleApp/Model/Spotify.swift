import Foundation
import Combine
import UIKit
import SwiftUI
import KeychainAccess
import SpotifyWebAPI

/**
 A helper class that wraps around an instance of `SpotifyAPI`
 and provides convenience methods for authorizing your application.
 
 Its most important role is to handle changes to the authorzation
 information and save them to persistent storage in the keychain.
 */
final class Spotify: ObservableObject {
    
    private static let clientId: String = {
        if let clientId = ProcessInfo.processInfo
            .environment["client_id"] {
            return clientId
        }
        fatalError("Could not find 'client_id' in environment variables")
    }()
    
    private static let clientSecret: String = {
        if let clientSecret = ProcessInfo.processInfo
            .environment["client_secret"] {
            return clientSecret
        }
        fatalError("Could not find 'client_secret' in environment variables")
    }()
    
    /// The key in the keychain that is used to store the authorization
    /// information: "authorizationManager".
    static let authorizationManagerKey = "authorizationManager"
    
    /// The URL that Spotify will redirect to after the user either
    /// authorizes or denies authorization for your application.
    static let loginCallbackURL = URL(
        string: "spotify-api-example-app://login-callback"
    )!
    
    /// A cryptographically-secure random string used to ensure
    /// than an incoming redirect from Spotify was the result of a request
    /// made by this app, and not an attacker. **This value is regenerated**
    /// **after each authorization process completes.**
    var authorizationState = String.randomURLSafe(length: 128)
    
    /**
     Whether or not the application has been authorized. If `true`,
     then you can begin making requests to the Spotify web API
     using the `api` property of this class, which contains an instance
     of `SpotifyAPI`.
     
     When `false`, `LoginView` is presented, which prompts the user to
     login. When this is set to `true`, `LoginView` is dismissed.
     
     This property provides a convenient way for the user interface
     to be updated based on whether the user has logged in with their
     Spotify account yet. For example, you could use this property disable
     UI elements that require the user to be logged in.
     
     This property is updated by `handleChangesToAuthorizationManager()`,
     which is called every time the authorization information changes,
     and `authorizationManagerDidDeauthorize()`, which is called
     everytime `SpotifyAPI.authorizationManager.deauthorize()` is called.
     */
    @Published var isAuthorized = false
    
    /// If `true`, then the app is retrieving access and refresh tokens.
    /// Used by `LoginView` to present an activity indicator.
    @Published var isRetrievingTokens = false
    
    @Published var currentUser: SpotifyUser? = nil
    
    /// The keychain to store the authorization information in.
    let keychain = Keychain(service: "com.Peter-Schorn.SpotifyAPIExampleApp")
    
    /// An instance of `SpotifyAPI` that you use to make requests to
    /// the Spotify web API.
    let api = SpotifyAPI(
        authorizationManager: AuthorizationCodeFlowManager(
            clientId: Spotify.clientId, clientSecret: Spotify.clientSecret
        )
    )
    
    var cancellables: Set<AnyCancellable> = []
    
    // MARK: - Methods -
    
    init() {
        
        // Configure the loggers.
        self.api.apiRequestLogger.logLevel = .trace
        // self.api.logger.logLevel = .trace
        
        // MARK: Important: Subscribe to `authorizationManagerDidChange` BEFORE
        // MARK: retrieving `authorizationManager` from persistent storage
        self.api.authorizationManagerDidChange
            // We must receive on the main thread because we are
            // updating the @Published `isAuthorized` property.
            .receive(on: RunLoop.main)
            .sink(receiveValue: handleChangesToAuthorizationManager)
            .store(in: &cancellables)
        
        self.api.authorizationManagerDidDeauthorize
            .receive(on: RunLoop.main)
            .sink(receiveValue: authorizationManagerDidDeauthorize)
            .store(in: &cancellables)
        
        
        // MARK: Check to see if the authorization information is saved in
        // MARK: the keychain.
        if let authManagerData = keychain[data: Self.authorizationManagerKey] {
            
            do {
                // Try to decode the data.
                let authorizationManager = try JSONDecoder().decode(
                    AuthorizationCodeFlowManager.self,
                    from: authManagerData
                )
                print("found authorization information in keychain")
                
                /*
                 This assignment causes `authorizationManagerDidChange`
                 to emit a signal, meaning that
                 `handleChangesToAuthorizationManager()` will be called.
                 
                 Note that if you had subscribed to
                 `authorizationManagerDidChange` after this line,
                 then `handleChangesToAuthorizationManager()` would not
                 have been called and the @Published `isAuthorized` property
                 would not have been properly updated.
                 
                 We do not need to update `isAuthorized` here because it
                 is already done in `handleChangesToAuthorizationManager()`.
                 */
                self.api.authorizationManager = authorizationManager
                
            } catch {
                print("could not decode authorizationManager from data:\n\(error)")
            }
        }
        else {
            print("did NOT find authorization information in keychain")
        }
        
        
    }
    
    /**
     A convenience method that creates the authorization URL and opens it
     in the browser.
     
     You could also configure it to accept parameters for the authorization
     scopes.
     
     This is called when the user taps the "Log in with Spotify" button
     in `LoginView`.
     */
    func authorize() {
        
        let url = api.authorizationManager.makeAuthorizationURL(
            redirectURI: Self.loginCallbackURL,
            showDialog: true,
            // This same value **MUST** be provided for the state parameter of
            // `authorizationManager.requestAccessAndRefreshTokens(redirectURIWithQuery:state:)`.
            // Otherwise, an error will be thrown.
            state: authorizationState,
            scopes: [
                .userReadPlaybackState,
                .userModifyPlaybackState,
                .playlistModifyPrivate,
                .playlistModifyPublic,
                .userLibraryRead,
                .userLibraryModify,
                .userReadEmail,
            ]
        )!
        
        // You can open the URL however you like. For example, you could open
        // it in a web view instead of the browser.
        // See https://developer.apple.com/documentation/webkit/wkwebview
        UIApplication.shared.open(url)
        
    }
    
    func requestAccessAndRefreshTokens(
        url: URL
    ) -> AnyPublisher<Void, Error> {
        
        // **Always** validate URLs; they offer a potential attack
        // vector into your app.
        guard url.scheme == Spotify.loginCallbackURL.scheme else {
            return SpotifyLocalError.other(
                "unexpected scheme in url: \(url)",
                localizedDescription: "The redirect could not be handled"
            )
            .anyFailingPublisher()
            
        }
        
        print("received redirect from Spotify: '\(url)'")
        
        // This property is used to display an activity indicator in
        // `LoginView` indicating that the access and refresh tokens
        // are being retrieved.
        self.isRetrievingTokens = true
        
        // MARK: IMPORTANT: generate a new value for the state parameter
        // MARK: after each authorization request. This ensures an incoming
        // MARK: redirect from Spotify was the result of a request made by
        // MARK: this app, and not an attacker.
        defer {
            self.authorizationState = String.randomURLSafe(length: 128)
        }
        
        // Complete the authorization process by requesting the
        // access and refresh tokens.
        return self.api.authorizationManager.requestAccessAndRefreshTokens(
            redirectURIWithQuery: url,
            // This value must be the same as the one used to create the
            // authorization URL. Otherwise, an error will be thrown.
            state: self.authorizationState
        )
        .flatMap(self.api.currentUserProfile)
        .map { (user: SpotifyUser) -> Void in
            
        }
        .handleEvents(receiveCompletion: { completion in
            // Whether the request succeeded or not, we need to remove
            // the activity indicator.
            self.isRetrievingTokens = false
        })
        .receive(on: RunLoop.main)
        .eraseToAnyPublisher()
        

    }

    /**
     Saves changes to `api.authorizationManager` to the keychain.
     
     This method is called every time the authorization information changes. For
     example, when the access token gets automatically refreshed, (it expires after
     an hour) this method will be called.
     
     It will also be called after the access and refresh tokens are retrieved using
     `requestAccessAndRefreshTokens(redirectURIWithQuery:state:)`.
     
     Read the full documentation for [SpotifyAPI.authorizationManagerDidChange][1].
     
     [1]: https://peter-schorn.github.io/SpotifyAPI/Classes/SpotifyAPI.html#/s:13SpotifyWebAPI0aC0C29authorizationManagerDidChange7Combine18PassthroughSubjectCyyts5NeverOGvp
     */
    func handleChangesToAuthorizationManager() {
        
        withAnimation(LoginView.animation) {
            // Update the @Published `isAuthorized` property.
            // When set to `true`, `LoginView` is dismissed, allowing the
            // user to interact with the rest of the app.
            self.isAuthorized = self.api.authorizationManager.isAuthorized()
        }
        
        print(
            "Spotify.handleChangesToAuthorizationManager: isAuthorized:",
            self.isAuthorized
        )
        
        
        self.retrieveCurrentUser(onlyIfNil: true)
        
        // Don't save the authorization manager to persistent storage here
        // if we just retrieved the access and refresh tokens. Instead,
        // we'll do that in `Spotify.requestAccessAndRefreshTokens(url:)`,
        guard !self.isRetrievingTokens else { return }

        do {
            // Encode the authorization information to data.
            let authManagerData = try JSONEncoder().encode(
                self.api.authorizationManager
            )
            
            // Save the data to the keychain.
            keychain[data: Self.authorizationManagerKey] = authManagerData
            print("did save authorization manager to keychain")
            
        } catch {
            print(
                "couldn't encode authorizationManager for storage " +
                    "in keychain:\n\(error)"
            )
        }
        
    }
    
    /**
     Removes `api.authorizationManager` from the keychain and sets
     `currentUser` to `nil`.
     
     This method is called everytime `api.authorizationManager.deauthorize` is
     called.
     */
    func authorizationManagerDidDeauthorize() {
        
        withAnimation(LoginView.animation) {
            self.isAuthorized = false
        }
        
        self.currentUser = nil
        
        do {
            /*
             Remove the authorization information from the keychain.
             
             If you don't do this, then the authorization information
             that you just removed from memory by calling
             `SpotifyAPI.authorizationManager.deauthorize()` will be
             retrieved again from persistent storage after this app is
             quit and relaunched.
             */
            try keychain.remove(Self.authorizationManagerKey)
            print("did remove authorization manager from keychain")
            
        } catch {
            print(
                "couldn't remove authorization manager " +
                "from keychain: \(error)"
            )
        }
    }

    /**
     Retrieve the current user.
     
     - Parameter onlyIfNil: Only retrieve the user if `self.currentUser`
           is `nil`.
     */
    func retrieveCurrentUser(onlyIfNil: Bool) {
        
        if onlyIfNil && self.currentUser != nil {
            return
        }

        guard self.isAuthorized else { return }

        self.api.currentUserProfile()
            .receive(on: RunLoop.main)
            .sink(
                receiveCompletion: { completion in
                    if case .failure(let error) = completion {
                        print("couldn't retrieve current user: \(error)")
                    }
                },
                receiveValue: { user in
                    self.currentUser = user
                }
            )
            .store(in: &cancellables)
        
    }

}
