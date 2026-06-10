import { Component } from "@angular/core";
import { bootstrapApplication } from "@angular/platform-browser";
import { RouterOutlet, provideRouter } from "@angular/router";

@Component({
  selector: "app-root",
  imports: [RouterOutlet],
  template: `
    <main>
      <h1>npm tarball cache workload</h1>
      <p>Angular production build completed.</p>
      <router-outlet />
    </main>
  `
})
class AppComponent {}

bootstrapApplication(AppComponent, {
  providers: [provideRouter([])]
}).catch((error: unknown) => console.error(error));
