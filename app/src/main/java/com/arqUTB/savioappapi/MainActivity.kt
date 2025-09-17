package com.arqUTB.savioappapi

import android.annotation.SuppressLint
import android.content.Intent
import android.graphics.Bitmap
import android.os.Bundle
import android.webkit.CookieManager
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity

class MainActivity : AppCompatActivity() {
    private lateinit var webView: WebView
    private lateinit var txtStatus: TextView
    private lateinit var progress: ProgressBar
    private lateinit var overlay: LinearLayout

    private var intentando = false
    private var listo = false
    private var intentos = 0
    private val MAX_INTENTOS = 12
    private val START_URL = "https://savio.utb.edu.co/" // inicio que dispara SSO

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        supportActionBar?.hide()

        webView = findViewById(R.id.webView)
        txtStatus = findViewById(R.id.txtStatus)
        progress = findViewById(R.id.progress)
        overlay = findViewById(R.id.overlay)

        // Mostrar overlay de carga al inicio
        overlay.visibility = LinearLayout.VISIBLE
        webView.visibility = WebView.INVISIBLE

        val cm = CookieManager.getInstance()
        cm.setAcceptCookie(true)
        cm.setAcceptThirdPartyCookies(webView, true)

        with(webView.settings) {
            javaScriptEnabled = true
            domStorageEnabled = true
            userAgentString = userAgentString + " SavioApp/1.0"
        }

        configurarCliente()
        txtStatus.text = "Abriendo login..."
        webView.loadUrl(START_URL)
    }

    private fun configurarCliente() {
        webView.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean = false
            override fun onPageStarted(view: WebView?, url: String?, favicon: Bitmap?) {
                overlay.visibility = LinearLayout.VISIBLE
                txtStatus.text = "Cargando portal..."
            }
            override fun onPageFinished(view: WebView?, url: String?) {
                overlay.visibility = LinearLayout.VISIBLE
                txtStatus.text = "Validando sesión..."
                if (!listo) verificarSesion()
            }
        }
    }

    private fun verificarSesion() {
        if (intentando || listo) return
        intentando = true
        intentos++
        val js = """(function(){try{var u=document.querySelector('.userbutton .usertext');if(u&&u.textContent.trim().length>0){return 'OK';}var mailBtn=document.querySelector('.theme-loginform button.login-open');if(mailBtn&&/@/.test(mailBtn.textContent)) return 'OK';return 'NO';}catch(e){return 'NO';}})();""".trimIndent()
        webView.evaluateJavascript(js) { res ->
            intentando = false
            if (res?.contains("OK") == true) {
                listo = true
                UserSession.accessToken = "webview-session"
                overlay.visibility = LinearLayout.VISIBLE
                txtStatus.text = "¡Sesión iniciada! Entrando..."
                progress.visibility = ProgressBar.VISIBLE
                abrirMenuDirecto()
            } else if (intentos < MAX_INTENTOS) {
                txtStatus.text = "Verificando sesión ($intentos/$MAX_INTENTOS)..."
                progress.visibility = ProgressBar.VISIBLE
                overlay.visibility = LinearLayout.VISIBLE
                webView.postDelayed({ verificarSesion() }, 900)
            } else {
                txtStatus.text = "Por favor inicia sesión en el portal y espera..."
                progress.visibility = ProgressBar.VISIBLE
                overlay.visibility = LinearLayout.VISIBLE
                intentos = MAX_INTENTOS - 2
                webView.postDelayed({ verificarSesion() }, 3000)
            }
        }
    }

    private fun abrirMenuDirecto() {
        // Oculta overlay antes de abrir el menú
        overlay.visibility = LinearLayout.GONE
        webView.visibility = WebView.INVISIBLE
        startActivity(Intent(this, MenuActivity::class.java))
        overridePendingTransition(0,0)
        finish()
    }
}
