// SPDX-License-Identifier: GPL-2.0-or-later
// mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import SwiftUI
import WebKit
import AppKit
import MRNGCore

/// WKWebView that accepts self-signed certificates (intended for LAN use)
/// and auto-fills username/password from confCons.xml on page load.
final class HTTPSWebView: WKWebView, WKNavigationDelegate {
    var autofillUser: String = ""
    var autofillPass: String = ""

    func webView(_ webView: WKWebView,
                 didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Self-signed certificate on LAN.
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        // HTTP Basic / Digest -> send the node's credentials if we have any.
        if challenge.previousFailureCount == 0,
           !autofillUser.isEmpty,
           (challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPBasic
            || challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPDigest
            || challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodNTLM) {
            let cred = URLCredential(user: autofillUser, password: autofillPass, persistence: .forSession)
            completionHandler(.useCredential, cred)
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        injectAutofill()
    }

    /// Detects the first <input type="password"> and the nearest user field;
    /// fills the values and dispatches input/change events so JS frameworks
    /// (React/Vue) "see" the change. Does NOT auto-submit.
    private func injectAutofill() {
        guard !autofillUser.isEmpty || !autofillPass.isEmpty else { return }
        let u = jsString(autofillUser)
        let p = jsString(autofillPass)
        let hasUser = autofillUser.isEmpty ? "false" : "true"
        let hasPass = autofillPass.isEmpty ? "false" : "true"
        let js = """
        (function(){
          if (window.__mrngAutofillInstalled) return;
          window.__mrngAutofillInstalled = true;
          var USER = \(u), PASS = \(p);
          var hasUser = \(hasUser), hasPass = \(hasPass);
          var filledPw = false, filledUser = false;
          var attempts = 0, maxAttempts = 60; // ~18s at 300ms

          function visible(el){
            if (!el) return false;
            if (el.disabled || el.readOnly) return false;
            if (el.offsetParent === null && el.type !== 'hidden') {
              // some inputs are position:fixed -> offsetParent is null but they are visible
              var r = el.getBoundingClientRect();
              if (r.width === 0 || r.height === 0) return false;
            }
            return true;
          }
          function setVal(el, v){
            if (!el) return;
            try {
              var proto = Object.getPrototypeOf(el);
              var setter = Object.getOwnPropertyDescriptor(proto, 'value');
              if (setter && setter.set) setter.set.call(el, v); else el.value = v;
            } catch(e){ el.value = v; }
            el.dispatchEvent(new Event('input', {bubbles:true}));
            el.dispatchEvent(new Event('change', {bubbles:true}));
            el.dispatchEvent(new KeyboardEvent('keyup', {bubbles:true}));
          }
          function findUserField(pw){
            // Strategy 1: visible input before pw (in the form, or in the document)
            var scope = pw.form || document;
            var inputs = Array.prototype.slice.call(scope.querySelectorAll('input'));
            var before = null;
            for (var i = 0; i < inputs.length; i++) {
              if (inputs[i] === pw) break;
              var t = (inputs[i].type || 'text').toLowerCase();
              if (t === 'password' || t === 'hidden' || t === 'submit' || t === 'button' || t === 'checkbox' || t === 'radio') continue;
              if (visible(inputs[i])) before = inputs[i];
            }
            if (before) return before;
            // Strategy 2: visible input AFTER pw (rare, but it happens)
            var idx = inputs.indexOf(pw);
            for (var j = idx + 1; j < inputs.length; j++) {
              var t2 = (inputs[j].type || 'text').toLowerCase();
              if (t2 === 'password' || t2 === 'hidden' || t2 === 'submit' || t2 === 'button' || t2 === 'checkbox' || t2 === 'radio') continue;
              if (visible(inputs[j])) return inputs[j];
            }
            // Strategy 3: match by attributes (name/id/autocomplete/placeholder)
            var hints = ['username','user','login','email','account','userid','uid'];
            for (var k = 0; k < inputs.length; k++) {
              var el = inputs[k];
              if (!visible(el)) continue;
              var attrs = ((el.name||'')+' '+(el.id||'')+' '+(el.autocomplete||'')+' '+(el.placeholder||'')).toLowerCase();
              for (var h = 0; h < hints.length; h++) {
                if (attrs.indexOf(hints[h]) >= 0) return el;
              }
            }
            return null;
          }
          function tryFill(){
            attempts++;
            var pw = null;
            var allPw = document.querySelectorAll('input[type="password"]');
            for (var i = 0; i < allPw.length; i++) { if (visible(allPw[i])) { pw = allPw[i]; break; } }
            if (!pw) return false;
            if (hasPass && !filledPw) { setVal(pw, PASS); filledPw = true; }
            if (hasUser && !filledUser) {
              var uf = findUserField(pw);
              if (uf) { setVal(uf, USER); filledUser = true; }
            }
            return filledPw && (!hasUser || filledUser);
          }
          if (tryFill()) return;
          var iv = setInterval(function(){
            if (tryFill() || attempts >= maxAttempts) clearInterval(iv);
          }, 300);
          // MutationObserver for SPAs that mount the form lazily
          try {
            var mo = new MutationObserver(function(){ if (tryFill()) mo.disconnect(); });
            mo.observe(document.documentElement, {childList:true, subtree:true});
            setTimeout(function(){ mo.disconnect(); }, 20000);
          } catch(e){}
        })();
        """
        evaluateJavaScript(js, completionHandler: nil)
    }

    private func jsString(_ s: String) -> String {
        // JSON-encode so quotes, backslashes and unicode are properly escaped.
        if let data = try? JSONSerialization.data(withJSONObject: [s], options: []),
           let str = String(data: data, encoding: .utf8) {
            // [\"...\"] -> \"...\"
            let trimmed = str.dropFirst().dropLast()
            return String(trimmed)
        }
        return "\"\""
    }
}

struct HTTPContainer: NSViewRepresentable {
    let session: Session

    func makeNSView(context: Context) -> HTTPSWebView {
        let config = WKWebViewConfiguration()
        let webView = HTTPSWebView(frame: .zero, configuration: config)
        webView.autofillUser = session.node.username
        webView.autofillPass = session.password
        webView.navigationDelegate = webView
        if let url = Self.url(for: session.node) {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateNSView(_ nsView: HTTPSWebView, context: Context) {
        // Pick up credentials if they changed in the editor while the tab was open.
        nsView.autofillUser = session.node.username
        nsView.autofillPass = session.password
    }

    static func url(for node: MRNGNode) -> URL? {
        let scheme = node.protocolType.lowercased() // "http" or "https"
        let host = node.hostname
        guard !host.isEmpty else { return nil }
        let defaultPort = (scheme == "https") ? 443 : 80
        var s = "\(scheme)://\(host)"
        if node.port != defaultPort { s += ":\(node.port)" }
        return URL(string: s)
    }
}
